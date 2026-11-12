import XCTest
@testable import BigDaddy

/// 心跳带回的同步令牌与配置里存的令牌是"要不要重拉配置"的唯一依据，两边的字段名都不能漂。
final class SyncTokenDecodingTests: XCTestCase {
    func testHeartbeatResponseCarriesSyncToken() throws {
        let json = #"{"serverTime":"2026-11-12T10:00:00","syncToken":"abc123","hasPendingCommand":true}"#
        let decoded = try JSONDecoder.bigDaddy.decode(HeartbeatResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.syncToken, "abc123")
        XCTAssertEqual(decoded.hasPendingCommand, true)
    }

    func testClientConfigKeepsSyncTokenAcrossSaveAndLoad() throws {
        let json = #"{"bound":true,"syncToken":"abc123"}"#
        let config = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.syncToken, "abc123")
        let roundTripped = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTripped.syncToken, "abc123")
    }
}
