import XCTest
@testable import BigDaddy

final class WebFilterPolicyTests: XCTestCase {
    func testDisabledPolicyAlwaysAllows() {
        let policy = makePolicy(enabled: false, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])

        XCTAssertFalse(policy.blocks(hostname: "example.com"))
        XCTAssertFalse(policy.blocks(hostname: "www.example.com"))
    }

    func testExactRuleDoesNotBlockSubdomains() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: false)
        ])

        XCTAssertTrue(policy.blocks(hostname: "example.com"))
        XCTAssertFalse(policy.blocks(hostname: "www.example.com"))
    }

    func testSubdomainRuleMatchesDomainBoundary() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])

        XCTAssertTrue(policy.blocks(hostname: "EXAMPLE.COM."))
        XCTAssertTrue(policy.blocks(hostname: "cdn.example.com"))
        XCTAssertFalse(policy.blocks(hostname: "notexample.com"))
    }

    func testUnboundDeviceAlwaysAllows() {
        let policy = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(
                enabled: true,
                revision: 7,
                blockedDomains: [WebFilterRule(domain: "example.com", includeSubdomains: true)]
            ),
            isDeviceBound: false,
            appliedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(policy.blocks(hostname: "example.com"))
        XCTAssertFalse(policy.enabled)
    }

    func testPolicyRoundTripsThroughVendorConfiguration() throws {
        let policy = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(
                enabled: true,
                revision: 8,
                blockedDomains: [WebFilterRule(domain: "example.com", includeSubdomains: true)]
            ),
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 0)
        )

        let vendorConfiguration = try WebFilterPolicyTransport.vendorConfiguration(for: policy)

        XCTAssertEqual(WebFilterPolicyTransport.policy(from: vendorConfiguration), policy)
    }

    func testProviderAcknowledgementConfirmsMatchingPolicy() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])

        XCTAssertTrue(WebFilterProviderAcknowledgement(policy: policy).confirms(policy))
    }

    func testProviderAcknowledgementConfirmsSamePolicyAfterClientRestart() {
        let configuration = WebFilterConfiguration(
            enabled: true,
            revision: 7,
            blockedDomains: [WebFilterRule(domain: "example.com", includeSubdomains: true)]
        )
        let appliedPolicy = WebFilterPolicySnapshot(
            configuration: configuration,
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 0)
        )
        let restartedClientPolicy = WebFilterPolicySnapshot(
            configuration: configuration,
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(WebFilterProviderAcknowledgement(policy: appliedPolicy).confirms(restartedClientPolicy))
    }

    func testProviderAcknowledgementRejectsStaleOrDifferentPolicy() {
        let appliedPolicy = makePolicy(enabled: false, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])
        let currentPolicy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])

        XCTAssertFalse(WebFilterProviderAcknowledgement(policy: appliedPolicy).confirms(currentPolicy))
    }

    func testProviderAcknowledgementRejectsDifferentRulesWithSameRevisionAndCount() {
        let appliedPolicy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])
        let currentPolicy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.org", includeSubdomains: true)
        ])

        XCTAssertFalse(WebFilterProviderAcknowledgement(policy: appliedPolicy).confirms(currentPolicy))
    }

    private func makePolicy(
        enabled: Bool,
        rules: [WebFilterRule]
    ) -> WebFilterPolicySnapshot {
        WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(
                enabled: enabled,
                revision: 7,
                blockedDomains: rules
            ),
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
