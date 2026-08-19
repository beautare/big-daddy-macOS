import XCTest
@testable import BigDaddy

/// QUIC 长包头字节特征识别。
///
/// 这是继"押在系统远端端点 API 上"两次静默失效之后换上的主判据——不再问系统"这是不是
/// QUIC"，直接读包本身。两个方向都要测：漏判（浏览器又一次悄悄绕过限制）和误判（把别的
/// UDP 协议流量误当 QUIC 掐掉，无征兆打断这台 Mac 上别的程序）。
final class QUICPacketTests: XCTestCase {

    private func quicInitialHeader(version: UInt32, flags: UInt8 = 0xC0) -> Data {
        var bytes: [UInt8] = [flags]
        bytes.append(UInt8((version >> 24) & 0xFF))
        bytes.append(UInt8((version >> 16) & 0xFF))
        bytes.append(UInt8((version >> 8) & 0xFF))
        bytes.append(UInt8(version & 0xFF))
        bytes.append(contentsOf: [0x00, 0x00, 0x00]) // 后续字节无关紧要，只是凑够长度
        return Data(bytes)
    }

    func testRecognizesQUICv1() {
        XCTAssertTrue(QUICPacket.looksLikeQUIC(quicInitialHeader(version: 0x0000_0001)))
    }

    func testRecognizesQUICv2() {
        XCTAssertTrue(QUICPacket.looksLikeQUIC(quicInitialHeader(version: 0x6b33_43cf)))
    }

    func testRecognizesDraft29() {
        XCTAssertTrue(QUICPacket.looksLikeQUIC(quicInitialHeader(version: 0xff00_001d)))
    }

    /// 版本协商包（version 全零）刻意不认——它不携带任何连接意图，掐它没有意义，
    /// 也不该出现在"认出了 QUIC 就掐断"这条链路里。
    func testDoesNotRecognizeVersionNegotiationPacket() {
        XCTAssertFalse(QUICPacket.looksLikeQUIC(quicInitialHeader(version: 0x0000_0000)))
    }

    /// 未在册的版本号（比如未来的草案）宁可漏判，不猜。宽松匹配的代价是把 UDP 上其它
    /// 协议的流量误判成 QUIC 掐掉——那个代价比漏拦一次 QUIC 大得多。
    func testRejectsUnknownVersion() {
        XCTAssertFalse(QUICPacket.looksLikeQUIC(quicInitialHeader(version: 0xdead_beef)))
    }

    /// 高两位必须精确匹配 11（长包头 + QUIC 固定位）。只挪低位、不碰高两位的变体
    /// 不该被认成 QUIC——这条钉住的是"判据只看高两位"这类过度宽松实现会犯的错。
    func testRejectsShortHeaderEvenWithKnownVersionBytes() {
        var bytes = [UInt8](quicInitialHeader(version: 0x0000_0001))
        bytes[0] = 0x40 // 短包头（最高位 0），不是长包头
        XCTAssertFalse(QUICPacket.looksLikeQUIC(Data(bytes)))
    }

    func testRejectsTooShortData() {
        XCTAssertFalse(QUICPacket.looksLikeQUIC(Data([0xC0, 0x00, 0x00, 0x00])))
        XCTAssertFalse(QUICPacket.looksLikeQUIC(Data()))
    }

    /// TLS 记录层（TCP 上的 ClientHello 外层）不该被误认成 QUIC——首字节 0x16
    /// （handshake record type）高两位是 00，天然过不了长包头那道检查，这里显式钉住
    /// 这个交叉场景，不依赖 HandshakeHostnameTests 里那个 file-private 的完整 fixture。
    func testDoesNotMisidentifyTLSRecordAsQUIC() {
        let tlsRecordHeader = Data([0x16, 0x03, 0x01, 0x00, 0xF8])
        XCTAssertFalse(QUICPacket.looksLikeQUIC(tlsRecordHeader))
    }
}
