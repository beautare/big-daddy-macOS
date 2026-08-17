import XCTest
@testable import BigDaddy

/// TimeSessionAnchor 是"睡眠+离线时倒计时按墙钟走，同时防孩子改系统时钟"这条设计的
/// 唯一落点（见 BigDaddyClient.swift 类型定义的注释）。这里只测纯函数本身，不需要真机
/// 睡眠或改钟——用可控的 now/systemUptime 参数模拟四种场景。
final class TimeSessionAnchorTests: XCTestCase {
    /// 正常在线运行：两个锚点没有分叉，与只用单锚时读数完全一致。
    func testNormalOperationBothAnchorsAgree() {
        let now = Date()
        let uptime: TimeInterval = 100_000
        let anchor = TimeSessionAnchor(
            sessionId: "s1",
            uptimeDeadline: uptime + 60,
            wallDeadline: now.addingTimeInterval(60)
        )
        XCTAssertEqual(anchor.remainingSeconds(now: now, systemUptime: uptime), 60)
    }

    /// 合盖睡眠：systemUptime 在睡眠期间不推进，但墙钟照走。10 分钟约定睡了 10 分钟后
    /// 醒来，wallDeadline 早已过去——必须靠它把剩余算成 0，而不是让 uptime 那边继续
    /// 显示"还剩 10 分钟"（那正是缺口 2 的原始 bug：睡眠期间倒计时零消耗）。
    func testSleepIsCountedByWallClock() {
        let sessionStart = Date()
        let uptimeAtSessionStart: TimeInterval = 100_000
        let anchor = TimeSessionAnchor(
            sessionId: "s1",
            uptimeDeadline: uptimeAtSessionStart + 600,
            wallDeadline: sessionStart.addingTimeInterval(600)
        )
        // 睡了 10 分钟：墙钟往前走了 600 秒，但系统运行时长（uptime）分毫未动。
        let afterSleepWall = sessionStart.addingTimeInterval(600)
        let afterSleepUptime = uptimeAtSessionStart
        XCTAssertEqual(anchor.remainingSeconds(now: afterSleepWall, systemUptime: afterSleepUptime), 0)
    }

    /// 孩子把系统时间往后拨 2 小时：wallDeadline 被动推远，但 uptimeDeadline 只认
    /// systemUptime，不受影响——必须靠它继续按真实经过的时间判到点，不能被拨钟绕过。
    func testClockSetForwardIsCaughtByUptimeAnchor() {
        let sessionStart = Date()
        let uptimeAtSessionStart: TimeInterval = 100_000
        let anchor = TimeSessionAnchor(
            sessionId: "s1",
            uptimeDeadline: uptimeAtSessionStart + 60,
            wallDeadline: sessionStart.addingTimeInterval(60)
        )
        // 时钟被拨到 2 小时后，但只过去了 90 秒的真实系统运行时长。
        let tamperedWall = sessionStart.addingTimeInterval(2 * 3600)
        let realUptime = uptimeAtSessionStart + 90
        XCTAssertEqual(anchor.remainingSeconds(now: tamperedWall, systemUptime: realUptime), 0)
    }

    /// 孩子把系统时间往前拨：wallDeadline 被推近甚至已过去，uptime 还没到——这种情况下
    /// 提前到点是可接受的行为（服务端仍是权威，下一次成功的 refreshConfig 会纠正），
    /// 不是本方案要堵的漏洞，这里明确把它写成断言而不是留白。
    func testClockSetBackwardCanExpireEarly() {
        let sessionStart = Date()
        let uptimeAtSessionStart: TimeInterval = 100_000
        let anchor = TimeSessionAnchor(
            sessionId: "s1",
            uptimeDeadline: uptimeAtSessionStart + 600,
            wallDeadline: sessionStart.addingTimeInterval(600)
        )
        // 时钟被拨快 5 分钟，真实只过去了 10 秒系统运行时长。
        let advancedWall = sessionStart.addingTimeInterval(600 + 5 * 60)
        let realUptime = uptimeAtSessionStart + 10
        XCTAssertEqual(anchor.remainingSeconds(now: advancedWall, systemUptime: realUptime), 0)
    }

    /// 不足一秒的余量进位成 1，与原先 `.rounded(.up)` 的读数习惯保持一致，避免归零前
    /// 最后一瞬间显示 "0:00" 却还没真正到点。
    func testSubSecondRemainderRoundsUpToOne() {
        let now = Date()
        let uptime: TimeInterval = 100_000
        let anchor = TimeSessionAnchor(
            sessionId: "s1",
            uptimeDeadline: uptime + 0.4,
            wallDeadline: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(anchor.remainingSeconds(now: now, systemUptime: uptime), 1)
    }

    /// 已经过期的锚点钳制在 0，不返回负数——调用方（timeSessionTick 等）都是拿它直接
    /// 判 `<= 0`，一个负数不会让判断出错，但也没有理由允许它存在。
    func testAlreadyExpiredClampsToZero() {
        let now = Date()
        let uptime: TimeInterval = 100_000
        let anchor = TimeSessionAnchor(
            sessionId: "s1",
            uptimeDeadline: uptime - 100,
            wallDeadline: now.addingTimeInterval(-100)
        )
        XCTAssertEqual(anchor.remainingSeconds(now: now, systemUptime: uptime), 0)
    }
}
