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

    // MARK: - continuityModeUpdatedAt decoding

    func testMissingContinuityModeUpdatedAtDecodesNil() throws {
        let config = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: Data("{}".utf8))
        XCTAssertNil(config.continuityModeUpdatedAt)
    }

    func testContinuityModeUpdatedAtDecodesJacksonLocalDateTimeFormat() throws {
        // 后端 Jackson 序列化 LocalDateTime 就长这样：无时区、带小数秒。
        let config = try JSONDecoder.bigDaddy.decode(
            ClientConfig.self,
            from: Data(#"{"continuityModeUpdatedAt":"2026-07-16T23:01:02.123456"}"#.utf8)
        )
        XCTAssertNotNil(config.continuityModeUpdatedAt)
    }

    // MARK: - ConfigStore 本地往返（JSONEncoder.bigDaddy / JSONDecoder.bigDaddy 必须配对）
    //
    // 这三条钉住此前从未被触发过的一个坑：ConfigStore.save() 一旦用普通 JSONEncoder()
    // （默认把 Date 编码成距 2001 参考日的秒数），而 ConfigStore.load() 用的
    // JSONDecoder.bigDaddy 无条件按字符串解析 Date——ClientConfig 只要携带一个非 nil
    // 的 Date 字段存盘，下次启动就会在这个字段上解码失败，进而让整份本地配置静默退回
    // 默认值。continuityModeUpdatedAt 是 ClientConfig 里第一个 Date 字段，直接会踩中。

    func testDateRoundTripsThroughBigDaddyEncoderAndDecoder() throws {
        var config = ClientConfig()
        config.continuityMode = true
        config.continuityModeUpdatedAt = Date(timeIntervalSince1970: 1_755_000_000)

        let data = try JSONEncoder.bigDaddy.encode(config)
        let decoded = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: data)

        let original = try XCTUnwrap(config.continuityModeUpdatedAt)
        let restored = try XCTUnwrap(decoded.continuityModeUpdatedAt)
        // ISO 8601 格式化到毫秒精度，不奢求跟原始 Date 完全相等，但秒级必须对得上。
        XCTAssertEqual(original.timeIntervalSince1970, restored.timeIntervalSince1970, accuracy: 0.001)
    }

    func testNilDateRoundTripsAsNil() throws {
        let config = ClientConfig()
        let data = try JSONEncoder.bigDaddy.encode(config)
        let decoded = try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: data)
        XCTAssertNil(decoded.continuityModeUpdatedAt)
    }

    func testPlainJSONEncoderIsNotSymmetricWithBigDaddyDecoder() throws {
        // 反证：证明这个坑是真实存在的，不是臆造的风险。用错误的编码器（旧 ConfigStore.save()
        // 用过的那个）编码一个带 Date 的 config，再拿 JSONDecoder.bigDaddy 解码，必须失败——
        // 如果这条用例哪天开始通过，说明 Foundation 悄悄改了默认行为，上面两条"往返成功"的
        // 用例就不再能证明什么，需要重新审视。
        var config = ClientConfig()
        config.continuityModeUpdatedAt = Date()
        let data = try JSONEncoder().encode(config)
        XCTAssertThrowsError(try JSONDecoder.bigDaddy.decode(ClientConfig.self, from: data))
    }

    // MARK: - shouldClearOverride 决策逻辑

    func testClearOverrideOnFalseToTrueEdge() {
        XCTAssertTrue(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: false,
            remoteUpdatedAt: nil,
            overrideBaseline: nil
        ))
    }

    func testDoesNotClearWhenRemoteStillFalse() {
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: false,
            previousContinuityMode: false,
            remoteUpdatedAt: Date(),
            overrideBaseline: Date.distantPast
        ))
    }

    func testDoesNotClearWhenNoEdgeAndNoBaseline() {
        // 家长从未真正动过这个开关（没有 baseline 可比），也没观察到边沿：不该清。
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: nil,
            overrideBaseline: nil
        ))
    }

    func testClearsOnFreshTimestampEvenWithoutObservingEdge() {
        // 核心场景：家长关了又开，两次保存都发生在客户端两次轮询之间——本次轮询看到的
        // 仍是 true→true（没有边沿），但时间戳比创建覆盖时的快照新，照样要清。
        let baseline = Date(timeIntervalSince1970: 1000)
        let newerUpdate = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: newerUpdate,
            overrideBaseline: baseline
        ))
    }

    func testDoesNotClearOnStaleOrEqualTimestamp() {
        let baseline = Date(timeIntervalSince1970: 2000)
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: baseline,
            overrideBaseline: baseline
        ))
        XCTAssertFalse(ContinuityModeController.shouldClearOverride(
            remoteContinuityMode: true,
            previousContinuityMode: true,
            remoteUpdatedAt: Date(timeIntervalSince1970: 500),
            overrideBaseline: baseline
        ))
    }

    func testOldBackendWithoutTimestampFallsBackToEdgeOnly() {
        // 旧后端不下发 continuityModeUpdatedAt：remoteUpdatedAt 恒 nil，baseline 也恒 nil
        // （从未存过），行为必须退回纯边沿判断，不能因为新逻辑而“坏得更差”。
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
        let key = "ContinuityModeOverrideBaselineUpdatedAt"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        ContinuityModePreference.overrideBaseline = nil
        XCTAssertNil(ContinuityModePreference.overrideBaseline)

        let snapshot = Date(timeIntervalSince1970: 1_700_000_000)
        ContinuityModePreference.overrideBaseline = snapshot
        XCTAssertEqual(ContinuityModePreference.overrideBaseline, snapshot)

        ContinuityModePreference.overrideBaseline = nil
        XCTAssertNil(ContinuityModePreference.overrideBaseline)
    }
}
