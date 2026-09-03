import XCTest
@testable import BigDaddy

/// 多屏截图靠"同一个请求里的多个同名 file 部分"送到后端，顺序即屏幕编号。
/// multipart 是手写拼的，分隔符错一个字节就会让服务端少收一块屏、或者整个请求解析失败，
/// 而这类错误只在真机上传时才暴露。
final class ScreenshotUploadBodyTests: XCTestCase {
    private let boundary = "TestBoundary"

    /// 只用来断言 multipart 的文本骨架。图片字节故意用合法 UTF-8 范围内的值，
    /// 否则整段解码失败会返回空串，让断言以一个与被测代码无关的理由失败。
    /// 真实二进制字节的完整性由 testImageBytesSurviveIntact 直接按字节验证。
    private func text(_ data: Data) -> String {
        guard let s = String(data: data, encoding: .utf8) else {
            XCTFail("multipart body 不是合法 UTF-8，无法按文本断言")
            return ""
        }
        return s
    }

    func testSingleScreenKeepsOriginalFilename() {
        let body = BigDaddyClient.multipartBody(boundary: boundary, images: [Data([0x41])])
        let s = text(body)
        XCTAssertTrue(s.contains("filename=\"screenshot.jpg\""), s)
        XCTAssertFalse(s.contains("screen-1.jpg"), s)
        XCTAssertEqual(s.components(separatedBy: "name=\"file\"").count - 1, 1)
    }

    func testEachScreenBecomesItsOwnFilePart() {
        let body = BigDaddyClient.multipartBody(boundary: boundary,
                                                images: [Data([0x01]), Data([0x02]), Data([0x03])])
        let s = text(body)
        // 三个部分必须同名 file——后端是按 @RequestParam("file") 收成数组的
        XCTAssertEqual(s.components(separatedBy: "name=\"file\"").count - 1, 3)
        XCTAssertTrue(s.contains("filename=\"screen-1.jpg\""), s)
        XCTAssertTrue(s.contains("filename=\"screen-3.jpg\""), s)
    }

    func testPartsAreSeparatedAndTerminatedCorrectly() {
        let body = BigDaddyClient.multipartBody(boundary: boundary, images: [Data([0x01]), Data([0x02])])
        let s = text(body)
        // 每张图后面都要有 CRLF 才能接下一条 --boundary，最后一条是 --boundary--
        XCTAssertEqual(s.components(separatedBy: "--\(boundary)\r\n").count - 1, 2)
        XCTAssertTrue(s.hasSuffix("--\(boundary)--\r\n"), s)
    }

    func testImageBytesSurviveIntact() {
        // 图片是二进制，拼接过程不能碰它的字节（比如被当成文本转码）
        let first = Data([0xFF, 0xD8, 0x00, 0x0A, 0x0D])
        let body = BigDaddyClient.multipartBody(boundary: boundary, images: [first])
        XCTAssertTrue(body.range(of: first) != nil)
    }
}

/// 主屏在 payload 里的位置不能靠"第一张就是主屏"这种位置假设——主屏静止不变时
/// 恰恰最容易被按屏去重跳过，副屏反而会排到前面。这几条用例覆盖的正是曾经出过错
/// 的地方：必须按原始显示器 index（1 恒代表主屏）精确定位，而不是猜位置。
final class MainScreenPositionTests: XCTestCase {
    func testMainScreenSurvivesAndStaysFirst() {
        // 三块屏都进了 payload，主屏（index 1）本来就在第一位
        XCTAssertEqual(BigDaddyClient.mainScreenPosition(includedOriginalIndices: [1, 2, 3]), 1)
    }

    func testMainScreenSkippedLeavesSecondaryScreenFirstWithoutBeingMislabeled() {
        // 主屏（index 1）被去重跳过，只有副屏 2、3 幸存——它们排在 payload 前面，
        // 但绝不能因为"排第一"就被误认成主屏
        XCTAssertNil(BigDaddyClient.mainScreenPosition(includedOriginalIndices: [2, 3]))
    }

    func testFunctionLocatesMainScreenByIndexRegardlessOfListOrder() {
        // 真实调用方（captureAndSendScreenshot）里主屏若幸存必然排第一——captures 保留
        // 原始顺序、过滤不改变相对顺序，主屏又总排在原始列表最前。但这个函数本身不该
        // 依赖"主屏在前"这个调用方约定，它必须单靠 index==1 去定位，这里就故意打乱顺序
        // 验证这一点，避免以后哪次改动悄悄引入"其实是靠位置猜的"隐藏假设。
        XCTAssertEqual(BigDaddyClient.mainScreenPosition(includedOriginalIndices: [3, 1, 2]), 2)
    }

    func testNoScreensSurviveReturnsNil() {
        XCTAssertNil(BigDaddyClient.mainScreenPosition(includedOriginalIndices: []))
    }
}
