import XCTest
@testable import BigDaddy

final class WeeklyAccessTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1791194400) // 2026-10-05 18:00 Asia/Shanghai
    private var plan: WeeklyAccessPlan {
        WeeklyAccessPlan(id: "bilibili", name: "B站", enabled: true, timeZone: "Asia/Shanghai",
                         windows: [WeeklyAccessWindow(daysOfWeek: [1, 2], startMinute: 1080, endMinute: 1200)])
    }

    private func policy(blockedUntil: Int64? = nil, temporaryUntil: Int64? = nil) -> WebFilterPolicySnapshot {
        WebFilterPolicySnapshot(configuration: WebFilterConfiguration(
            enabled: true, revision: 42, blockedDomains: [
                WebFilterRule(domain: "bilibili.com", includeSubdomains: true, category: "ENTERTAINMENT", weeklyPlanId: plan.id),
                WebFilterRule(domain: "youtube.com", includeSubdomains: true, category: "ENTERTAINMENT"),
                WebFilterRule(domain: "bad.com", includeSubdomains: true)
            ], appRules: [AppNetworkRule(signingIdentifier: "com.steam", teamIdentifier: "ABCDEFGHIJ", displayName: "Steam", access: .agreement)],
            weeklyPlans: [plan], weeklyPlansBlockedUntilEpochMillis: blockedUntil,
            temporaryAllowedUntilEpochMillis: temporaryUntil), isDeviceBound: true, appliedAt: monday)
    }

    func testBoundariesWeekdaysAndFixedTimezone() {
        XCTAssertFalse(plan.isOpen(at: monday.addingTimeInterval(-1)))
        XCTAssertTrue(plan.isOpen(at: monday))
        XCTAssertTrue(plan.isOpen(at: monday.addingTimeInterval(7199)))
        XCTAssertFalse(plan.isOpen(at: monday.addingTimeInterval(7200)))
        XCTAssertTrue(plan.isOpen(at: monday.addingTimeInterval(86400)))
        XCTAssertFalse(plan.isOpen(at: monday.addingTimeInterval(2 * 86400)))
    }

    func testOnlyAssignedTargetOpensAndNeverRemainsBlocked() {
        let policy = policy()
        XCTAssertFalse(policy.blocks(hostname: "www.bilibili.com", at: monday))
        XCTAssertTrue(policy.blocks(hostname: "youtube.com", at: monday))
        XCTAssertTrue(policy.blocks(hostname: "bad.com", at: monday))
        let steam = AppIdentity(signingIdentifier: "com.steam.helper", teamIdentifier: "ABCDEFGHIJ", isPlatformBinary: false)
        XCTAssertEqual(policy.appVerdict(for: steam, at: monday), .block)
        XCTAssertTrue(policy.blocks(hostname: "bilibili.com", at: monday.addingTimeInterval(7200)))
    }

    func testAssignedAppOpensOnlyInItsWindowAndMidnightEndsTheDay() {
        var config = WebFilterConfiguration(enabled: true, appRules: [
            AppNetworkRule(signingIdentifier: "com.steam", teamIdentifier: "ABCDEFGHIJ", displayName: "Steam", access: .agreement, weeklyPlanId: plan.id)
        ], weeklyPlans: [plan])
        let steam = AppIdentity(signingIdentifier: "com.steam.helper", teamIdentifier: "ABCDEFGHIJ", isPlatformBinary: false)
        var policy = WebFilterPolicySnapshot(configuration: config, isDeviceBound: true, appliedAt: monday)
        XCTAssertEqual(policy.appVerdict(for: steam, at: monday), .bypass)
        XCTAssertEqual(policy.appVerdict(for: steam, at: monday.addingTimeInterval(7200)), .block)
        config.weeklyPlans = [WeeklyAccessPlan(id: plan.id, name: plan.name, enabled: true, timeZone: plan.timeZone,
            windows: [WeeklyAccessWindow(daysOfWeek: [1], startMinute: 1380, endMinute: 1440)])]
        policy = WebFilterPolicySnapshot(configuration: config, isDeviceBound: true, appliedAt: monday)
        let eleven = monday.addingTimeInterval(5 * 3600)
        let midnight = monday.addingTimeInterval(6 * 3600)
        XCTAssertEqual(policy.appVerdict(for: steam, at: eleven), .bypass)
        XCTAssertEqual(policy.appVerdict(for: steam, at: midnight), .block)
        XCTAssertEqual(policy.nextReevaluation(after: eleven), midnight)
    }

    func testLockdownExpiresLocallyWithoutNewServerConfig() {
        let end = monday.addingTimeInterval(3600)
        let policy = policy(blockedUntil: Int64(end.timeIntervalSince1970 * 1000))
        XCTAssertTrue(policy.blocks(hostname: "bilibili.com", at: monday))
        XCTAssertFalse(policy.blocks(hostname: "bilibili.com", at: end))
        XCTAssertTrue(self.policy(blockedUntil: -1).blocks(hostname: "bilibili.com", at: end))
    }

    func testOneTimeAllowanceAndLockdownPriority() {
        let beforeOpening = monday.addingTimeInterval(-3600)
        let deadline = Int64(monday.timeIntervalSince1970 * 1000)
        XCTAssertFalse(policy(temporaryUntil: deadline).blocks(hostname: "youtube.com", at: beforeOpening))
        XCTAssertTrue(policy(temporaryUntil: deadline).blocks(hostname: "bad.com", at: beforeOpening))
        XCTAssertTrue(policy(blockedUntil: -1, temporaryUntil: deadline).blocks(hostname: "youtube.com", at: beforeOpening))
    }

    func testNextBoundaryCanCloseExistingConnectionsAndScheduleNextWeek() {
        XCTAssertEqual(policy().nextReevaluation(after: monday), monday.addingTimeInterval(7200))
        XCTAssertEqual(policy().nextReevaluation(after: monday.addingTimeInterval(7200)), monday.addingTimeInterval(86400))
        XCTAssertEqual(plan.nextBoundary(after: monday.addingTimeInterval(2 * 86400)), monday.addingTimeInterval(7 * 86400))
    }

    func testPlanSurvivesPolicyTransportAndAcknowledgement() throws {
        let original = policy()
        let decoded = try XCTUnwrap(WebFilterPolicyTransport.policy(from: WebFilterPolicyTransport.vendorConfiguration(for: original)))
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.blocks(hostname: "bilibili.com", at: monday))
        XCTAssertTrue(WebFilterProviderAcknowledgement(policy: decoded).confirms(original))
        XCTAssertEqual(decoded.schemaVersion, 4)
    }

    func testOlderExtensionCannotClaimWeeklySupportByEchoingSchemaNumber() throws {
        let empty = WebFilterPolicySnapshot(configuration: WebFilterConfiguration(enabled: true), isDeviceBound: true, appliedAt: monday)
        let encoded = try JSONEncoder().encode(WebFilterProviderAcknowledgement(policy: empty))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "weeklyPlans")
        let older = try JSONDecoder().decode(WebFilterProviderAcknowledgement.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(older.policySchemaVersion, 3)
        XCTAssertTrue(older.confirms(empty))
        XCTAssertFalse(older.confirms(policy()))
    }
}
