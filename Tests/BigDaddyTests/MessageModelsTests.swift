import XCTest
@testable import BigDaddy

/// 短消息的数据模型：后端 JSON 能否原样解出来，以及 revision 不参与配置相等性比较。
final class MessageModelsTests: XCTestCase {
    func testConversationDecodesBackendPayload() throws {
        let json = """
        {"code":200,"message":"OK","data":{
          "mode":"PARENT_ONLY","timeRequestEnabled":true,"revision":"1760000000000",
          "canSendText":true,"sendBlockedReason":null,"replyWindowEndsAt":1760001800000,"repliesLeft":3,
          "canRequestTime":false,"timeRequestBlockedReason":"REQUEST_PENDING","timeRequestRetryAt":1760001800000,
          "requestMinuteOptions":[15,30,45,60],"retentionHours":24,"maxTextLength":100,"serverNow":1760000000000,
          "messages":[
            {"id":"a","sender":"PARENT","kind":"TEXT","text":"该睡觉了","sentAt":1760000000000,"expiresAt":1760086400000,
             "deliveredAt":1760000001000,"readAt":null},
            {"id":"b","sender":"CHILD","kind":"TIME_REQUEST","text":null,"minutes":30,"requestStatus":"PENDING",
             "sentAt":1760000100000,"expiresAt":1760086500000}
          ]}}
        """.data(using: .utf8)!
        let conversation = try JSONDecoder.bigDaddy.decode(ApiResponse<ChatConversation>.self, from: json).data
        XCTAssertEqual(conversation.mode, "PARENT_ONLY")
        XCTAssertEqual(conversation.repliesLeft, 3)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.unreadParentMessages.map(\.id), ["a"])
        XCTAssertTrue(conversation.messages[1].isTimeRequest)
        XCTAssertEqual(conversation.messages[1].minutes, 30)
    }

    func testOlderBackendWithoutFieldsStillDecodes() throws {
        let json = #"{"code":200,"message":"OK","data":{}}"#.data(using: .utf8)!
        let conversation = try JSONDecoder.bigDaddy.decode(ApiResponse<ChatConversation>.self, from: json).data
        XCTAssertEqual(conversation.mode, "OFF")
        XCTAssertFalse(conversation.hasAnyEntry)
    }

    func testRevisionDoesNotMakeConfigLookChanged() {
        var a = ClientConfig()
        var b = ClientConfig()
        a.messaging = ClientMessagingSummary(mode: "PARENT_ONLY", timeRequestEnabled: true, revision: "1")
        b.messaging = ClientMessagingSummary(mode: "PARENT_ONLY", timeRequestEnabled: true, revision: "2")
        XCTAssertEqual(a, b, "a new message must not look like a config change")
        b.messaging?.mode = "TWO_WAY"
        XCTAssertNotEqual(a, b)
    }

    func testClientConfigDecodesMessagingSummary() throws {
        let json = #"{"bound":true,"messaging":{"mode":"TWO_WAY","timeRequestEnabled":false,"revision":"9"}}"#.data(using: .utf8)!
        let config = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: json)
        XCTAssertEqual(config.messaging?.mode, "TWO_WAY")
        XCTAssertEqual(config.messaging?.revision, "9")
    }
}
