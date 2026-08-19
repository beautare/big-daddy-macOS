import Foundation

/// 从一条连接最开头的出站字节里认出它要去的主机名。
///
/// **为什么非有不可。** Apple 对 `NEFilterSocketFlow.remoteHostname` 的原话是
/// "This property is only non-nil if the flow was created using Network.framework or
/// NSURLSession"。Safari 走的正是这条路，所以域名黑名单对它有效；而 Chrome / Arc /
/// Firefox 自己做 DNS 解析、再直接 connect 到 IP，系统手里没有这条流和域名的对应关系，
/// `remoteHostname` 就是 nil——黑名单对它们完全失效。实测也是这个结论：curl 和 Safari
/// 拦得住，Chrome 拦不住；把 Chrome 的 DoH 和 QUIC 都关掉之后，Chrome 立刻就拦住了。
///
/// 握手包里的主机名跟"DNS 是谁解析的"无关：TLS 的 ClientHello 带明文 SNI，明文 HTTP
/// 带 Host 头。从这里读，对所有浏览器一视同仁。
///
/// **已知读不到的两种情况**（都会退化成放行，不会误拦）：
/// - QUIC：ClientHello 在加密的 Initial 包里。由调用方另行处理（生效期间丢弃 UDP 443，
///   浏览器会自动回落到 TCP+TLS，那条路的 ClientHello 是明文的）。
/// - TLS Encrypted Client Hello (ECH)：真实 SNI 被加密，外层只有一个占位域名。
///   目前尚未普及，但它一旦铺开，任何基于 SNI 的过滤都会失效——这是这套方案的天花板。
enum HandshakeHostname {
    static func host(in data: Data) -> String? {
        TLSClientHello.serverName(in: data) ?? HTTPRequestHead.host(in: data)
    }
}

/// 认出一条流是不是 QUIC——**只看字节，不问系统**。
///
/// **为什么不能问系统。** 原来判 QUIC 靠的是"socketProtocol 是 UDP 且远端端口是 443"，
/// 端口从 `NEFilterSocketFlow.remoteEndpoint` 取。那个属性 macOS 15 起就废弃了，实测在
/// 新系统上取不到值；换用替代品 `remoteFlowEndpoint` 之后**依然**取不到。两次都是静默
/// 失败：没有报错、没有降级提示，只是 QUIC 从此再没被认出来过。
///
/// 后果极其隐蔽：域名黑名单对 HTTP/3 天然无效（QUIC 的 ClientHello 整个加密，SNI 读不
/// 出来），全靠"认出是 QUIC 就掐掉、逼它回落到明文握手的 TCP+TLS"这一手。这一手一瞎，
/// youtube 这类默认走 HTTP/3 的站点就完全绕过限制，而 bilibili 这类走 TCP 的照常被拦——
/// 表现成"有的网站秒拦、有的怎么都拦不住"，且没有任何报错指向真正的原因。
///
/// 所以改成看包本身。QUIC 长包头的头 5 个字节是稳定且自证的：
///
///   第 0 字节  1 1 T T R R P P   最高位 = 长包头形式，次高位 = 固定位（QUIC 强制为 1）
///   第 1..4 字节                 32 位版本号
///
/// 只认版本号明确在册的那几个，不做"高两位对上就算"的宽松判断——UDP 上什么协议都有，
/// 宽松匹配会把别的程序的流量误当成 QUIC 掐掉，那个代价比漏拦大得多。
enum QUICPacket {
    /// 在册的 QUIC 版本号。v1 是当前所有浏览器的默认；v2 已在 RFC 9369 定稿；两个 draft
    /// 是仍能在真实流量里遇到的历史版本。版本协商包（version = 0）刻意不认——它不携带
    /// 任何连接意图，掐它没有意义。
    private static let knownVersions: Set<UInt32> = [
        0x0000_0001, // RFC 9000 (QUIC v1)
        0x6b33_43cf, // RFC 9369 (QUIC v2)
        0xff00_001d, // draft-29
        0xfaceb002, // Google QUIC Q046 之后的 draft 变体
    ]

    /// data 是这条流最开头的出站字节。QUIC 的第一个包必然是长包头（Initial），
    /// 所以只看开头就够——不必等攒齐整个握手。
    static func looksLikeQUIC(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        let bytes = [UInt8](data.prefix(5))
        // 高两位必须是 11：最高位标记长包头，次高位是 QUIC 的固定位。
        guard (bytes[0] & 0xC0) == 0xC0 else { return false }
        let version = (UInt32(bytes[1]) << 24)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 8)
            | UInt32(bytes[4])
        return knownVersions.contains(version)
    }
}

/// TLS ClientHello 里的 SNI（server_name 扩展）。
///
/// 全程边界检查，任何一步对不上就返回 nil ——**认不出来一律当作"不知道"，绝不猜**。
/// 这条通路上误判的代价是不对称的：漏掉一个域名只是少拦一次，而误拦会毫无征兆地
/// 掐断孩子电脑上任意一个程序的网络。
enum TLSClientHello {
    private static let handshakeContentType: UInt8 = 0x16
    private static let clientHelloType: UInt8 = 0x01
    private static let serverNameExtension = 0x0000
    private static let hostNameType: UInt8 = 0x00

    static func serverName(in data: Data) -> String? {
        var reader = ByteReader(data)

        guard reader.byte() == handshakeContentType else { return nil }
        guard reader.skip(2) else { return nil }                       // 记录层版本
        guard let recordLength = reader.uint16() else { return nil }
        // 记录还没收全就先不判：调用方会再要一些字节回来重试
        guard reader.remaining >= recordLength else { return nil }

        guard reader.byte() == clientHelloType else { return nil }
        guard reader.skip(3) else { return nil }                       // 握手消息长度
        guard reader.skip(2) else { return nil }                       // 客户端版本
        guard reader.skip(32) else { return nil }                      // random

        guard let sessionIDLength = reader.byte(), reader.skip(Int(sessionIDLength)) else { return nil }
        guard let cipherSuitesLength = reader.uint16(), reader.skip(cipherSuitesLength) else { return nil }
        guard let compressionLength = reader.byte(), reader.skip(Int(compressionLength)) else { return nil }
        guard let extensionsLength = reader.uint16() else { return nil }

        var budget = extensionsLength
        while budget >= 4 {
            guard let type = reader.uint16(), let length = reader.uint16() else { return nil }
            budget -= 4
            guard budget >= length else { return nil }
            budget -= length

            if type == serverNameExtension {
                return hostName(from: &reader, length: length)
            }
            guard reader.skip(length) else { return nil }
        }
        return nil
    }

    /// server_name 扩展体：2 字节列表长度，随后是若干 (1 字节类型 + 2 字节长度 + 内容)。
    /// 只取 host_name(0) 那一项——其余类型至今没有被实际使用过。
    private static func hostName(from reader: inout ByteReader, length: Int) -> String? {
        guard let listLength = reader.uint16(), listLength <= length - 2 else { return nil }
        var budget = listLength
        while budget >= 3 {
            guard let nameType = reader.byte(), let nameLength = reader.uint16() else { return nil }
            budget -= 3
            guard budget >= nameLength, let bytes = reader.take(nameLength) else { return nil }
            budget -= nameLength
            guard nameType == hostNameType else { continue }
            guard let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty else { return nil }
            return name
        }
        return nil
    }
}

/// 明文 HTTP 请求头里的 Host。
///
/// 现在的孩子多半只会撞上 https，但 http 站点仍然存在，而且这一段几乎不要钱。
/// 必须先确认它长得像个 HTTP 请求再找 Host，否则任意二进制流里凑巧出现 "host:"
/// 就会被当成域名——那是误拦的来源。
enum HTTPRequestHead {
    private static let methods = ["GET ", "POST ", "HEAD ", "PUT ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT "]

    static func host(in data: Data) -> String? {
        // 只看前 4 KiB：请求头再长也该结束了，而且这样不会为了一条大 POST 扫描整个 body
        let prefix = data.prefix(4096)
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }
        guard methods.contains(where: { text.hasPrefix($0) }) else { return nil }

        for line in text.split(separator: "\r\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }   // 头部结束
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "host" else { continue }
            // Host 可能带端口（example.com:8080），域名匹配只认主机部分
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            let hostOnly = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? value
            return hostOnly.isEmpty ? nil : hostOnly
        }
        return nil
    }
}

/// 一个只会往前走、每一步都做边界检查的字节游标。
private struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - index }

    mutating func byte() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func uint16() -> Int? {
        guard remaining >= 2 else { return nil }
        defer { index += 2 }
        return Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        index += count
        return true
    }

    mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }
}
