import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit
import Security
import ServiceManagement

extension JSONDecoder {
    /// 后端 Jackson 序列化 LocalDateTime 输出 "2026-07-16T23:01:02.123456"——无时区、带小数秒，
    /// 而 Foundation 的 .iso8601 策略要求带时区、不带小数秒，解析必然失败。曾导致 bind-with-code
    /// 的成功响应（boundAt 非空）解析失败被吞掉，误报"绑定失败"。这里两类格式都接受。
    static var bigDaddy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = BigDaddyDateParser.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(raw)")
        }
        return decoder
    }
}

extension JSONEncoder {
    /// 与 JSONDecoder.bigDaddy 配对，给 ConfigStore 把 ClientConfig 存盘再读回来用。
    ///
    /// 这是**预防性**的：ClientConfig 目前一个 Date 字段都没有（continuityModeUpdatedAt
    /// 存的是后端原文字符串），所以换不换编码器眼下没有任何行为差别。留着是因为
    /// save() 和 load() 之间存在一处很容易踩、且踩了没有任何报错的不对称——普通
    /// JSONEncoder() 默认把 Date 编成距 2001 参考日的秒数（Double），而
    /// JSONDecoder.bigDaddy 的自定义策略无条件按字符串解析。将来只要有人往
    /// ClientConfig 里加一个 Date 字段，存盘再读回来就会在那个字段上解码失败，
    /// 而 load() 是 `try?`，失败的后果不是这一个字段丢了，是**整份本地配置**
    /// 静默退回默认值。这里让编码端输出 BigDaddyDateParser 认得的 ISO 8601 字符串，
    /// 把这个陷阱一次性堵死。
    static var bigDaddy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(BigDaddyDateFormatter.iso8601Fractional.string(from: date))
        }
        return encoder
    }
}

/// **输出**用的共享 ISO 8601 formatter（解析走 BigDaddyDateParser，那边另有一套
/// 兼容多种格式的实例）。
///
/// 单独共享一份的理由是频率：ISO8601DateFormatter 的构造并不便宜（内部要建一个
/// CFDateFormatter 并绑 locale），而 sendHeartbeat 一次就要用三四回，心跳本身又由
/// **每次前台切换应用**触发（见 startActivitySwitchTracking，2 秒防抖），密集 alt-tab
/// 时这是全 App 最高频的路径；AuditLog.record 也是每条记录新建一个。
///
/// 配置完之后只调 string(from:)/date(from:)，与 BigDaddyDateParser 里那几个共享静态
/// 实例同一个用法。默认 formatOptions（.withInternetDateTime）必须保持不变——上报给
/// 后端的时间戳格式由它决定。
enum BigDaddyDateFormatter {
    static let iso8601 = ISO8601DateFormatter()
    /// 带小数秒的变体，供 JSONEncoder.bigDaddy 编码 ClientConfig 里的 Date 字段用——
    /// 必须跟 BigDaddyDateParser.iso8601Fractional 同一组 formatOptions，否则
    /// 编码端写出去的字符串解码端读不回来（该类型的注释详述了这个坑）。
    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum BigDaddyDateParser {
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601 = ISO8601DateFormatter()
    /// LocalDateTime 不携带时区，按本机时区解释
    private static let localDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = iso8601Fractional.date(from: raw) ?? iso8601.date(from: raw) {
            return date
        }
        // Jackson LocalDateTime 的小数秒位数不定（0–9 位），截掉后按秒级精度解析
        let withoutFraction = raw.split(separator: ".").first.map(String.init) ?? raw
        return localDateTime.date(from: withoutFraction)
    }
}

extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension HMAC<SHA256>.MAC {
    var data: Data { Data(self) }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
}
