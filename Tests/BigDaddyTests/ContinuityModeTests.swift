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
}
