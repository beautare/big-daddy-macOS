import XCTest
@testable import BigDaddy

/// 跑三端共用的网站判定判例（Fixtures/website-access-cases.json）。家长端（dashboard、iPhone）
/// 告诉家长"这个网站现在能不能打开"，这里是孩子 Mac 上真正执行拦截的那一端，结论必须一致。
final class SharedWebsiteAccessCasesTests: XCTestCase {
    private struct CaseFile: Decodable {
        let now: Date
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let config: WebFilterConfiguration
        let host: String
        let agreementOpen: Bool
        let lockdownActive: Bool
        let canOpen: Bool
    }

    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/website-access-cases.json")

    func testMacEnforcementMatchesSharedCases() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(CaseFile.self, from: Data(contentsOf: Self.fixtureURL))
        XCTAssertFalse(file.cases.isEmpty)
        let inAnHour = Int64((file.now.timeIntervalSince1970 + 3600) * 1000)

        for testCase in file.cases {
            // 服务端下发给 Mac 之前做的覆盖（BigDaddyService.applyWebLockdownOverride /
            // applyTimeSessionOverride）：临时拦截把开关强制打开、压住每周计划；限时放行给出截止时刻。
            var config = testCase.config
            if testCase.lockdownActive {
                if !config.enabled && config.mode == .allowSelected { config.mode = .blockSelected }
                config.enabled = true
                config.weeklyPlansBlockedUntilEpochMillis = inAnHour
            } else if testCase.agreementOpen {
                config.temporaryAllowedUntilEpochMillis = inAnHour
            }
            let policy = WebFilterPolicySnapshot(configuration: config, isDeviceBound: true)
            XCTAssertEqual(!policy.blocks(hostname: testCase.host, at: file.now), testCase.canOpen, testCase.name)
        }
    }
}
