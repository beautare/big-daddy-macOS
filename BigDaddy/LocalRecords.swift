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

/// 本机守护记录（知情透明）：把每一次实际发生的采集/上报动作追加到本地明文日志，
/// 孩子和家长都可以在设备上直接查看或导出，用于印证"采集了什么、什么时候采集"。
/// 这是"可导出审计留痕"的落地，不是隐蔽后台行为。
/// 自动更新当前走的是主 feed（官网 CDN）还是备用 feed（gh-pages + 直连 GitHub 下载）。
///
/// 从 AppDelegate 里挪出来单独成型，是因为它有两个互不相干的读者：AppDelegate 在
/// SPUUpdaterDelegate 回调里翻转它，而 sendHeartbeat 要把它捎给后端。**后者才是重点**——
/// "这台机器已经退到备用下载源了"只发生在孩子那台 Mac 上，本机不会有任何人看到，
/// 不随心跳上报就等于没人知道（本地 AuditLog 里那条 UPDATE_FEED_SWITCH 只有主动导出
/// 守护记录时才看得见，指望不上它来发现故障）。
///
/// 存 UserDefaults 而不是内存：feedURLString(for:) 要同步返回、没法跳回 @MainActor
/// 读属性，而 UserDefaults 本身线程安全；顺带也扛得住重启——官网出问题往往不是
/// 一两分钟的事。
enum UpdateFeedState {
    private static let usingFallbackKey = "BigDaddyUpdateFeedUsingFallback"
    private static let lastSwitchAtKey = "BigDaddyUpdateFeedLastSwitchAt"
    private static let lastErrorCodeKey = "BigDaddyUpdateFeedLastErrorCode"

    /// 下一次检查是否改用备用 feed。
    static var usingFallback: Bool {
        get { UserDefaults.standard.bool(forKey: usingFallbackKey) }
        set { UserDefaults.standard.set(newValue, forKey: usingFallbackKey) }
    }

    /// 最近一次主备切换发生在什么时候；从没切换过时为 nil。
    ///
    /// 光上报 usingFallback 这一个瞬时值是不够的：切换逻辑是**翻转**而不是锁死
    /// （见 AppDelegate 里的说明），主 feed 一直坏着时两个 feed 会交替上阵，心跳
    /// 恰好落在"这一轮用主 feed"上时 usingFallback 就是 false，故障看起来像没发生过。
    /// 有这个时间戳，后端才能按"最近还在反复切换"来判定，而不是靠抓那个瞬时值。
    static var lastSwitchAt: Date? {
        UserDefaults.standard.object(forKey: lastSwitchAtKey) as? Date
    }

    /// 触发最近一次切换的 Sparkle 错误码；从没切换过时为 nil。
    static var lastErrorCode: Int? {
        UserDefaults.standard.object(forKey: lastErrorCodeKey) as? Int
    }

    /// 记一次主备切换：翻转开关，并留下时刻和错误码供心跳上报。
    static func recordSwitch(toFallback: Bool, errorCode: Int) {
        usingFallback = toFallback
        UserDefaults.standard.set(Date(), forKey: lastSwitchAtKey)
        UserDefaults.standard.set(errorCode, forKey: lastErrorCodeKey)
    }
}

enum AuditLog {
    static var auditFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/guardian-audit.log")
    }

    static func record(_ line: String) {
        let stamp = BigDaddyDateFormatter.iso8601.string(from: Date())
        let entry = "\(stamp)\t\(line)\n"
        let url = auditFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = entry.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("BigDaddy: audit log write failed: \(error.localizedDescription)")
        }
    }

    /// 解绑时清空本地历史审计日志文件
    static func clear() {
        try? FileManager.default.removeItem(at: auditFileURL)
    }
}

enum ConfigStore {
    static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/config.json")
    }

    static func load() -> ClientConfig? {
        guard let data = try? Data(contentsOf: configFileURL) else { return nil }
        return try? JSONDecoder.bigDaddy.decode(ClientConfig.self, from: data)
    }

    static func save(_ config: ClientConfig) {
        do {
            try FileManager.default.createDirectory(at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder.bigDaddy
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            NSLog("BigDaddy failed to save config: \(error.localizedDescription)")
        }
    }
}
