import XCTest
@testable import BigDaddy

/// 握手包主机名识别。
///
/// 这里值得写密一点：这个解析器是 Chrome / Arc / Firefox 那条路上**唯一**的域名来源
/// （它们的 flow 上 remoteHostname 恒为 nil），解析错了就是静默漏拦；而边界判断写漏了
/// 又会把任意二进制流误认成某个域名，无征兆地掐断孩子电脑上别的程序。两个方向都得测。
final class HandshakeHostnameTests: XCTestCase {

    // MARK: - TLS ClientHello

    func testExtractsServerNameFromClientHello() {
        let hello = TLSFixture.clientHello(serverName: "www.youtube.com")
        XCTAssertEqual(TLSClientHello.serverName(in: hello), "www.youtube.com")
        XCTAssertEqual(HandshakeHostname.host(in: hello), "www.youtube.com")
    }

    func testExtractsServerNameWhenOtherExtensionsComeFirst() {
        // 真实的 ClientHello 里 server_name 前面通常还排着一堆别的扩展，
        // 解析必须老老实实按长度跳过它们，而不是在字节流里找特征串。
        let hello = TLSFixture.clientHello(
            serverName: "youtube.com",
            leadingExtensions: [
                (type: 0x002b, payload: [0x02, 0x03, 0x04]),          // supported_versions
                (type: 0x000a, payload: [0x00, 0x02, 0x00, 0x1d]),    // supported_groups
            ]
        )
        XCTAssertEqual(TLSClientHello.serverName(in: hello), "youtube.com")
    }

    func testHandlesNonEmptySessionIDAndCipherSuites() {
        let hello = TLSFixture.clientHello(
            serverName: "cdn.example.com",
            sessionID: [UInt8](repeating: 0xAB, count: 32),
            cipherSuites: [0x13, 0x01, 0x13, 0x02, 0x13, 0x03]
        )
        XCTAssertEqual(TLSClientHello.serverName(in: hello), "cdn.example.com")
    }

    func testReturnsNilWhenRecordIsIncomplete() {
        // 握手包被拆成几段送来时，前半段必须判成"还不知道"，让调用方再要一轮，
        // 而不是拿半个包硬解出个错误答案。
        let hello = TLSFixture.clientHello(serverName: "www.youtube.com")
        for cut in [5, 20, 40, hello.count - 3] {
            XCTAssertNil(
                TLSClientHello.serverName(in: hello.prefix(cut)),
                "截到 \(cut) 字节时不该给出结论"
            )
        }
    }

    func testIgnoresNonHandshakeTraffic() {
        XCTAssertNil(TLSClientHello.serverName(in: Data([0x17, 0x03, 0x03, 0x00, 0x10])))  // application data
        XCTAssertNil(TLSClientHello.serverName(in: Data()))
        XCTAssertNil(TLSClientHello.serverName(in: Data([0x16])))
    }

    func testDoesNotInventHostnameFromRandomBytes() {
        // 随机二进制不能被解出任何主机名——误拦比漏拦贵得多
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let noise = Data((0..<64).map { _ in UInt8.random(in: 0...255, using: &generator) })
            XCTAssertNil(HandshakeHostname.host(in: noise))
        }
    }

    func testClientHelloWithoutServerNameExtension() {
        let hello = TLSFixture.clientHello(serverName: nil)
        XCTAssertNil(TLSClientHello.serverName(in: hello))
    }

    // MARK: - 明文 HTTP

    func testExtractsHostHeader() {
        let request = Data("GET /watch?v=1 HTTP/1.1\r\nHost: www.youtube.com\r\nAccept: */*\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequestHead.host(in: request), "www.youtube.com")
        XCTAssertEqual(HandshakeHostname.host(in: request), "www.youtube.com")
    }

    func testHostHeaderIsCaseInsensitiveAndStripsPort() {
        let request = Data("POST /x HTTP/1.1\r\nhost:  example.com:8080  \r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequestHead.host(in: request), "example.com")
    }

    func testIgnoresHostLookalikeOutsideHTTPRequest() {
        // 不以 HTTP 方法开头的东西一律不认，否则任意载荷里出现 "Host:" 就会被误判
        let notHTTP = Data("\u{01}\u{02}binary junk Host: evil.example.com\r\n".utf8)
        XCTAssertNil(HTTPRequestHead.host(in: notHTTP))
        XCTAssertNil(HandshakeHostname.host(in: notHTTP))
    }

    func testIgnoresHostHeaderAfterHeadersEnd()  {
        // 空行之后是 body，body 里的 Host: 不是请求头
        let request = Data("GET / HTTP/1.1\r\nAccept: */*\r\n\r\nHost: evil.example.com\r\n".utf8)
        XCTAssertNil(HTTPRequestHead.host(in: request))
    }

    // MARK: - 与策略匹配串起来

    func testSNIFeedsDomainMatching() {
        let policy = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(
                enabled: true,
                revision: 1,
                blockedDomains: [WebFilterRule(domain: "youtube.com", includeSubdomains: true)]
            ),
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 0)
        )

        let blocked = TLSFixture.clientHello(serverName: "www.youtube.com")
        let allowed = TLSFixture.clientHello(serverName: "www.khanacademy.org")

        XCTAssertTrue(HandshakeHostname.host(in: blocked).map(policy.blocks(hostname:)) == true)
        XCTAssertTrue(HandshakeHostname.host(in: allowed).map(policy.blocks(hostname:)) == false)
    }
}

/// 按 RFC 8446 的布局手搓一个 ClientHello。用真实结构而不是录一段字节，
/// 是为了让"扩展顺序变了""session id 非空"这类变化都能在测试里表达出来。
private enum TLSFixture {
    static func clientHello(
        serverName: String?,
        sessionID: [UInt8] = [],
        cipherSuites: [UInt8] = [0x13, 0x01],
        leadingExtensions: [(type: Int, payload: [UInt8])] = []
    ) -> Data {
        var extensions: [UInt8] = []
        for ext in leadingExtensions {
            extensions += uint16(ext.type)
            extensions += uint16(ext.payload.count)
            extensions += ext.payload
        }
        if let serverName {
            let name = Array(serverName.utf8)
            var entry: [UInt8] = [0x00]           // host_name
            entry += uint16(name.count)
            entry += name
            var list = uint16(entry.count)
            list += entry
            extensions += uint16(0x0000)          // server_name
            extensions += uint16(list.count)
            extensions += list
        }

        var body: [UInt8] = []
        body += [0x03, 0x03]                      // client version
        body += [UInt8](repeating: 0x11, count: 32)  // random
        body += [UInt8(sessionID.count)] + sessionID
        body += uint16(cipherSuites.count) + cipherSuites
        body += [0x01, 0x00]                      // compression methods
        body += uint16(extensions.count) + extensions

        var handshake: [UInt8] = [0x01]           // ClientHello
        handshake += uint24(body.count)
        handshake += body

        var record: [UInt8] = [0x16, 0x03, 0x01]  // handshake record
        record += uint16(handshake.count)
        record += handshake
        return Data(record)
    }

    private static func uint16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint24(_ value: Int) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
