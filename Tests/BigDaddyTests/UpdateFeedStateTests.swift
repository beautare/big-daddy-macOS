import XCTest
@testable import BigDaddy

/// 下载源降级状态的行为约束。
///
/// 这套测试护的是一条**没有任何人会看到**的信号链：客户端从官网 CDN 回落到直连
/// GitHub 是完全静默的（只影响后台自动更新），本机界面上不会有任何提示。它能不能
/// 传出这台机器，全靠这三个字段被如实记下来、再随心跳带走。字段记错或漏记，
/// 表现就是"一批设备悄悄停在旧版本上，而没有任何信号指向原因"。
final class UpdateFeedStateTests: XCTestCase {
    private let keys = [
        "BigDaddyUpdateFeedUsingFallback",
        "BigDaddyUpdateFeedLastSwitchAt",
        "BigDaddyUpdateFeedLastErrorCode"
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    /// 干净安装：走主 feed，且"从没切换过"必须是 nil 而不是某个零值——
    /// 后端要靠 lastSwitchAt 判断"最近是否在反复切换"，把"从没发生过"混成
    /// 一个具体时刻会造出一条不存在的告警。
    func testDefaultsToPrimaryFeedWithNoSwitchHistory() {
        XCTAssertFalse(UpdateFeedState.usingFallback)
        XCTAssertNil(UpdateFeedState.lastSwitchAt)
        XCTAssertNil(UpdateFeedState.lastErrorCode)
    }

    /// 切到备用源时，三个字段都要落下来：光有开关不够，后端拿它当告警依据。
    func testRecordSwitchToFallbackCapturesAllThreeFields() {
        let before = Date()
        UpdateFeedState.recordSwitch(toFallback: true, errorCode: 1000)

        XCTAssertTrue(UpdateFeedState.usingFallback)
        XCTAssertEqual(UpdateFeedState.lastErrorCode, 1000)
        let at = try? XCTUnwrap(UpdateFeedState.lastSwitchAt)
        XCTAssertNotNil(at)
        if let at { XCTAssertGreaterThanOrEqual(at.timeIntervalSince1970, before.timeIntervalSince1970 - 1) }
    }

    /// 切回主源同样是一次"切换"，时间戳必须刷新。
    ///
    /// 这一条针对的是翻转式切换带来的观测陷阱：主 feed 一直坏着时两个源交替上阵，
    /// 心跳恰好落在"这一轮用主 feed"上时 usingFallback 就是 false。此时只有
    /// lastSwitchAt 还在往前走，能证明"这台机器仍在反复降级"。
    func testSwitchingBackToPrimaryStillRecordsTheSwitch() {
        UpdateFeedState.recordSwitch(toFallback: true, errorCode: 1002)
        let firstSwitch = UpdateFeedState.lastSwitchAt

        UpdateFeedState.recordSwitch(toFallback: false, errorCode: 2001)

        XCTAssertFalse(UpdateFeedState.usingFallback, "已经切回主源")
        XCTAssertEqual(UpdateFeedState.lastErrorCode, 2001)
        XCTAssertNotNil(UpdateFeedState.lastSwitchAt)
        if let first = firstSwitch, let second = UpdateFeedState.lastSwitchAt {
            XCTAssertGreaterThanOrEqual(second, first, "切回主源也要刷新时间戳，否则降级痕迹会被抹平")
        }
    }

    /// 一轮成功的检查只清开关，**不该**抹掉切换痕迹——痕迹被抹掉的话，
    /// 一次成功检查就能把刚刚发生过的降级从上报里洗干净。
    func testSuccessfulCheckClearsFlagButKeepsSwitchHistory() {
        UpdateFeedState.recordSwitch(toFallback: true, errorCode: 1000)

        UpdateFeedState.usingFallback = false   // AppDelegate 在 noUpdateError / 成功时走这条

        XCTAssertFalse(UpdateFeedState.usingFallback)
        XCTAssertNotNil(UpdateFeedState.lastSwitchAt, "降级痕迹必须留存，否则后端再也看不到它发生过")
        XCTAssertEqual(UpdateFeedState.lastErrorCode, 1000)
    }
}
