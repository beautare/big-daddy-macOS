import XCTest
@testable import BigDaddy

/// TimeSessionAnchorStore 是"离线冷启动能不能安全恢复旗帜"的落盘一半（内存那一半是
/// BigDaddyClient.init() 里读它的逻辑，见那段注释）。这里只测编解码本身的往返正确性——
/// 是否真的安全恢复取决于调用方对 wallDeadline 的判断，不在这个类型的职责内。
final class TimeSessionAnchorStoreTests: XCTestCase {
    override func tearDown() {
        TimeSessionAnchorStore.clear()
        super.tearDown()
    }

    func testSaveAndLoadRoundTripsAllFields() {
        let deadline = Date().addingTimeInterval(600)
        let anchor = PersistedTimeSessionAnchor(
            sessionId: "s1", wallDeadline: deadline, grantedSeconds: 900, note: "写完作业再玩"
        )
        TimeSessionAnchorStore.save(anchor)

        let loaded = TimeSessionAnchorStore.load()
        XCTAssertEqual(loaded?.sessionId, "s1")
        XCTAssertEqual(loaded?.grantedSeconds, 900)
        XCTAssertEqual(loaded?.note, "写完作业再玩")
        // 日期编解码走 JSONEncoder/Decoder.bigDaddy 的自定义 ISO 8601（带小数秒）策略，
        // 不是恒等精度——允许亚毫秒级误差，不用 XCTAssertEqual(Date, Date) 那种要求
        // 位级相同的比较方式。
        XCTAssertEqual(loaded?.wallDeadline.timeIntervalSince1970 ?? 0, deadline.timeIntervalSince1970, accuracy: 0.01)
    }

    func testNoteCanRoundTripAsNil() {
        let anchor = PersistedTimeSessionAnchor(
            sessionId: "s2", wallDeadline: Date().addingTimeInterval(60), grantedSeconds: 300, note: nil
        )
        TimeSessionAnchorStore.save(anchor)
        XCTAssertNil(TimeSessionAnchorStore.load()?.note)
    }

    func testLoadWithoutAnySavedAnchorReturnsNil() {
        TimeSessionAnchorStore.clear()
        XCTAssertNil(TimeSessionAnchorStore.load())
    }

    func testClearRemovesPersistedAnchor() {
        TimeSessionAnchorStore.save(PersistedTimeSessionAnchor(
            sessionId: "s3", wallDeadline: Date().addingTimeInterval(60), grantedSeconds: 300, note: nil
        ))
        XCTAssertNotNil(TimeSessionAnchorStore.load())
        TimeSessionAnchorStore.clear()
        XCTAssertNil(TimeSessionAnchorStore.load())
    }

    /// 一份最新写入会覆盖旧的那份，不会在磁盘上留下两条互相矛盾的记录——存储用的是
    /// 固定文件名的原子写入（.atomic），不是追加。
    func testSavingANewAnchorOverwritesThePrevious() {
        TimeSessionAnchorStore.save(PersistedTimeSessionAnchor(
            sessionId: "old", wallDeadline: Date().addingTimeInterval(60), grantedSeconds: 300, note: nil
        ))
        TimeSessionAnchorStore.save(PersistedTimeSessionAnchor(
            sessionId: "new", wallDeadline: Date().addingTimeInterval(120), grantedSeconds: 600, note: "new note"
        ))
        let loaded = TimeSessionAnchorStore.load()
        XCTAssertEqual(loaded?.sessionId, "new")
        XCTAssertEqual(loaded?.grantedSeconds, 600)
    }
}
