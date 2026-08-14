import XCTest
@testable import BigDaddy

final class ContinuityModeTests: XCTestCase {
    func testMissingContinuityModeDefaultsFalse() throws {
        let config = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(config.continuityMode)
    }

    func testContinuityModeTrueDecodes() throws {
        let config = try JSONDecoder.bigDaddy.decode(
            ClientConfig.self,
            from: Data(#"{"continuityMode":true}"#.utf8)
        )
        XCTAssertTrue(config.continuityMode)
    }

    func testContinuityModeFalseDecodes() throws {
        let config = try JSONDecoder.bigDaddy.decode(
            ClientConfig.self,
            from: Data(#"{"continuityMode":false,"screenshotEnabled":true}"#.utf8)
        )
        XCTAssertFalse(config.continuityMode)
        XCTAssertTrue(config.screenshotEnabled)
    }

    func testCrashRelaunchPlistUsesSuccessfulExitFalse() {
        let plist = LaunchAgentPlist.make(
            executablePath: "/tmp/BigDaddy",
            runAtLoad: true,
            crashRelaunch: true
        )
        XCTAssertEqual(plist["Label"] as? String, "com.bigdaddy.client")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/tmp/BigDaddy"])
        XCTAssertEqual(LaunchAgentPlist.runAtLoad(from: plist), true)
        XCTAssertTrue(LaunchAgentPlist.crashRelaunch(from: plist))
        let keepAlive = plist["KeepAlive"] as? [String: Bool]
        XCTAssertEqual(keepAlive?["SuccessfulExit"], false)
        let env = plist["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(env?[LaunchAgentPlist.launchedByLaunchdEnvKey], "1")
    }

    func testLoginOnlyPlistDisablesKeepAlive() {
        let plist = LaunchAgentPlist.make(
            executablePath: "/tmp/BigDaddy",
            runAtLoad: true,
            crashRelaunch: false
        )
        XCTAssertEqual(LaunchAgentPlist.crashRelaunch(from: plist), false)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(LaunchAgentPlist.runAtLoad(from: plist), true)
    }

    func testContinuityPlistCanDisableRunAtLoad() {
        let plist = LaunchAgentPlist.make(
            executablePath: "/tmp/BigDaddy",
            runAtLoad: false,
            crashRelaunch: true
        )
        XCTAssertTrue(LaunchAgentPlist.crashRelaunch(from: plist))
        XCTAssertFalse(LaunchAgentPlist.runAtLoad(from: plist))
    }

    func testPlistRoundTripPreservesKeepAliveShape() throws {
        let original = LaunchAgentPlist.make(
            executablePath: "/Applications/BigDaddy.app/Contents/MacOS/BigDaddy",
            runAtLoad: true,
            crashRelaunch: true
        )
        let data = try XCTUnwrap(LaunchAgentPlist.data(from: original))
        let parsed = try XCTUnwrap(LaunchAgentPlist.parse(data))
        XCTAssertTrue(LaunchAgentPlist.crashRelaunch(from: parsed))
        XCTAssertTrue(LaunchAgentPlist.runAtLoad(from: parsed))
        XCTAssertEqual(parsed["Label"] as? String, LaunchAgentPlist.label)
    }

    // MARK: - continuityModeUpdatedAt 解码（保留后端原文，不解析成 Date）

    func testMissingContinuityModeUpdatedAtDecodesNil() throws {
        let config = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: Data("{}".utf8))
        XCTAssertNil(config.continuityModeUpdatedAt)
    }

    func testContinuityModeUpdatedAtKeepsRawBackendString() throws {
        // 后端 Jackson 序列化 LocalDateTime 就长这样：无时区、带小数秒。必须原样留着——
        // 一旦解析成 Date，夏令时切换会让同一个字符串对应到不同的绝对时刻。
        let raw = "2026-07-16T23:01:02.123456"
        let config = try JSONDecoder.bigDaddy.decode(
            ClientConfig.self,
            from: Data(#"{"continuityModeUpdatedAt":"\#(raw)"}"#.utf8)
        )
        XCTAssertEqual(config.continuityModeUpdatedAt, raw)
    }

    // MARK: - ConfigStore 本地往返（JSONEncoder.bigDaddy / JSONDecoder.bigDaddy 必须配对）
    //
    // ClientConfig 目前没有 Date 字段，这几条钉的是那个**尚未被触发**的陷阱本身：
    // save() 若用普通 JSONEncoder()（Date -> 数字），而 load() 用 JSONDecoder.bigDaddy
    // （无条件按字符串解析 Date），两者对不上；又因为 load() 是 try?，后果不是丢一个
    // 字段，而是整份本地配置静默退回默认值。用一个独立小结构验证这对编解码器的对称性，
    // 不依赖 ClientConfig 当下有没有 Date 字段。
    private struct DateBox: Codable, Equatable {
        var stamp: Date?
    }

    func testDateRoundTripsThroughBigDaddyEncoderAndDecoder() throws {
        let box = DateBox(stamp: Date(timeIntervalSince1970: 1_755_000_000))
        let data = try JSONEncoder.bigDaddy.encode(box)
        let decoded = try JSONDecoder.bigDaddy.decode(DateBox.self, from: data)

        let original = try XCTUnwrap(box.stamp)
        let restored = try XCTUnwrap(decoded.stamp)
        // ISO 8601 格式化到毫秒精度，不奢求跟原始 Date 完全相等，但秒级必须对得上。
        XCTAssertEqual(original.timeIntervalSince1970, restored.timeIntervalSince1970, accuracy: 0.001)
    }

    func testNilDateRoundTripsAsNil() throws {
        let data = try JSONEncoder.bigDaddy.encode(DateBox(stamp: nil))
        XCTAssertNil(try JSONDecoder.bigDaddy.decode(DateBox.self, from: data).stamp)
    }

    func testPlainJSONEncoderIsNotSymmetricWithBigDaddyDecoder() throws {
        // 反证：证明这个陷阱真实存在，不是臆造的风险。如果这条哪天开始不抛错，说明
        // Foundation 改了默认行为，上面两条"往返成功"就不再能证明什么，需要重新审视。
        let data = try JSONEncoder().encode(DateBox(stamp: Date()))
        XCTAssertThrowsError(try JSONDecoder.bigDaddy.decode(DateBox.self, from: data))
    }

    // MARK: - shouldClearOverride 决策逻辑（等值比较，不比先后）

    func testClearOverrideOnFalseToTrueEdge() {
        XCTAssertTrue(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: false,
            remoteUpdatedAt: nil,
            overrideBaseline: nil
        ))
    }

    func testDoesNotClearWhenRemoteStillFalse() {
        // 家长那边还是关着：无论时间戳怎么变都不该清（清了等于替家长把它打开）。
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: false,
            previousContinuityMode: false,
            remoteUpdatedAt: "2026-08-14T10:00:00",
            overrideBaseline: nil
        ))
    }

    func testClearsOnChangedTokenEvenWithoutObservingEdge() {
        // 核心场景：家长关了又开，两次保存都落在客户端两次轮询之间——本次轮询看到的
        // 仍是 true→true（没有边沿），但时间戳变了，照样要清。
        XCTAssertTrue(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: "2026-08-14T10:00:00",
            overrideBaseline: "2026-08-01T09:00:00"
        ))
    }

    func testDoesNotClearWhenTokenUnchanged() {
        // 家长自打孩子建立覆盖之后就没动过：时间戳一字不差，必须保持覆盖。
        // 这条同时钉住"不跨夏令时误清"——原文相同就是相同，不经过时区解析。
        let token = "2026-08-14T10:00:00"
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: token,
            overrideBaseline: token
        ))
    }

    func testClearsWhenBaselineWasNilAndBackendNowHasToken() {
        // 老部署主场景：升级前就打开了连续性，新列是 NULL，孩子建立覆盖时快照只能是 nil。
        // 此后家长任何一次真正的翻转都会写出时间戳——从 nil 变成有值本身就是"家长动过"。
        // 这条曾经是 false（用先后比较时 nil baseline 让整条时间戳路径失效），
        // 意味着恰恰是存量用户拿不到这次修复。
        XCTAssertTrue(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: "2026-08-14T10:00:00",
            overrideBaseline: nil
        ))
    }

    func testOldBackendWithoutTokenFallsBackToEdgeOnly() {
        // 旧后端从不下发这个字段：两边恒 nil，相等，退回纯边沿判断，不能比改动前更差。
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: nil,
            overrideBaseline: nil
        ))
        XCTAssertTrue(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: false,
            remoteUpdatedAt: nil,
            overrideBaseline: nil
        ))
    }

    // MARK: - ContinuityModePreference.overrideBaseline 存取

    func testOverrideBaselineDefaultsNilAndRoundTrips() {
        let key = "ContinuityModeOverrideBaselineToken"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        ContinuityModePreference.overrideBaseline = nil
        XCTAssertNil(ContinuityModePreference.overrideBaseline)

        ContinuityModePreference.overrideBaseline = "2026-08-14T10:00:00"
        XCTAssertEqual(ContinuityModePreference.overrideBaseline, "2026-08-14T10:00:00")

        ContinuityModePreference.overrideBaseline = nil
        XCTAssertNil(ContinuityModePreference.overrideBaseline)
    }
}
