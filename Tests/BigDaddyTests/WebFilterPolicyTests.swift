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

    /// 回归测试：**解码出来的策略也必须能拦**。
    ///
    /// provider 拿到策略只有一条路——vendorConfiguration → `init(from:)`（见
    /// FilterDataProvider.reloadPolicy），构造器那条路只在主 App 侧走。匹配索引
    /// DomainMatcher 是不编码的派生数据，两个初始化器都得各自把它建起来；`init(from:)`
    /// 里漏掉的话，单测和主 App 全都照常绿灯，只有扩展里的 blocks() 会永远返回 false，
    /// 表现成"限制开着、什么都拦不住"，且没有任何报错。这条断言专门钉住那个缺口。
    func testDecodedPolicyStillBlocks() throws {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true),
            WebFilterRule(domain: "exact.org", includeSubdomains: false)
        ])
        let vendorConfiguration = try WebFilterPolicyTransport.vendorConfiguration(for: policy)
        let decoded = try XCTUnwrap(WebFilterPolicyTransport.policy(from: vendorConfiguration))

        XCTAssertTrue(decoded.blocks(hostname: "example.com"))
        XCTAssertTrue(decoded.blocks(hostname: "cdn.example.com"))
        XCTAssertTrue(decoded.blocks(hostname: "exact.org"))
        XCTAssertFalse(decoded.blocks(hostname: "www.exact.org"))
        XCTAssertFalse(decoded.blocks(hostname: "notexample.com"))
    }

    /// 多条规则混合时，includeSubdomains 必须**逐条**生效，不能被同一份索引里的
    /// 其他规则带歪：只有标了 includeSubdomains 的那条才吃子域。
    func testMixedRulesKeepPerRuleSubdomainScope() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "wide.com", includeSubdomains: true),
            WebFilterRule(domain: "narrow.com", includeSubdomains: false)
        ])

        XCTAssertTrue(policy.blocks(hostname: "wide.com"))
        XCTAssertTrue(policy.blocks(hostname: "a.b.wide.com"))
        XCTAssertTrue(policy.blocks(hostname: "narrow.com"))
        XCTAssertFalse(policy.blocks(hostname: "a.narrow.com"))
    }

    /// 规则侧的大小写/空白/尾点在建索引时就要归一化掉，跟主机名侧一样。
    func testRuleSideIsNormalizedWhenIndexed() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "  EXAMPLE.COM.  ", includeSubdomains: true)
        ])

        XCTAssertTrue(policy.blocks(hostname: "example.com"))
        XCTAssertTrue(policy.blocks(hostname: "CDN.Example.Com"))
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

    /// 回归测试：判定"扩展是否熬过了空窗期"必须看 providerStartedAt，不能看 appliedAt。
    ///
    /// 这正是最初写错的地方。主 App 每次启动都会无条件重写一次 vendorConfiguration
    /// （WebFilterController.enableContentFilter），provider 收到 KVO 就 reloadPolicy 并发一份
    /// appliedAt=now 的新回执；而这个判定恰恰发生在主 App 启动早期。于是用 appliedAt 判断时，
    /// 一个**从未重启过**的扩展也会被判成"重启过"，家长端因此显示一句与事实相反的话。
    func testProviderAcknowledgementDistinguishesProcessStartFromPolicyReapply() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])
        let gapStartedAt = Date(timeIntervalSince1970: 1_000)
        // 扩展进程在空窗期之前就起来了，全程没重启；但主 App 刚刚重启并重推了一次策略，
        // 所以 appliedAt 是"现在"，远晚于空窗期开始时刻。
        let acknowledgement = WebFilterProviderAcknowledgement(
            policy: policy,
            appliedAt: Date(timeIntervalSince1970: 2_000),
            providerStartedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertTrue(
            acknowledgement.providerStartedAt.map { $0 < gapStartedAt } ?? false,
            "providerStartedAt 早于空窗期开始 ⇒ 扩展确实熬过来了"
        )
        XCTAssertFalse(
            acknowledgement.appliedAt < gapStartedAt,
            "appliedAt 会被启动时的策略重推刷新，用它判断进程存活必然得出相反结论"
        )
    }

    /// 旧版扩展不带 providerStartedAt，解码成 nil ⇒ 调用方按"问不出来"处理，
    /// 绝不能退化成"没存活"（那会向家长报告一件没发生过的事）。
    func testProviderAcknowledgementWithoutProcessStartIsUnknownNotFalse() {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])
        let acknowledgement = WebFilterProviderAcknowledgement(policy: policy)

        XCTAssertNil(acknowledgement.providerStartedAt)
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
