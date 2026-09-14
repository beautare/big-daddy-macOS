import XCTest
@testable import BigDaddy

final class ActivityInfoCollectorTests: XCTestCase {
    func testResponsiveBrowserReturnsDetails() async {
        let info = await ActivityInfoCollector().capture { ("Window", "https://example.com") }
        XCTAssertEqual(info.title, "Window")
        XCTAssertEqual(info.url, "https://example.com")
    }

    func testBlockedBrowserDoesNotBlockHeartbeatOrSpawnMoreCaptures() async {
        let collector = ActivityInfoCollector()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = await collector.capture(timeout: 0.02) {
            release.wait()
            return ("Late result", "")
        }
        XCTAssertEqual(first.title, "")
        let second = await collector.capture(timeout: 0.02) {
            XCTFail("Previous Apple Event is still running; do not enqueue another")
            return ("", "")
        }
        XCTAssertEqual(second.title, "")
    }
}
