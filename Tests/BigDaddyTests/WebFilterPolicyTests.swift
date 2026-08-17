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

    /// 主 App → provider 的策略推送用这对裸编解码（不套 vendorConfiguration 那层 key）。
    /// 必须跟 vendorConfiguration 路径产出逐位相同的字节，两条通道送到的才是可比较、
    /// 可去重的同一份数据——见 FilterDataProvider.applyPolicy 的注释。
    func testBarePolicyCodecRoundTripsAndMatchesVendorConfigurationBytes() throws {
        let policy = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "example.com", includeSubdomains: true)
        ])

        let pushedData = try XCTUnwrap(WebFilterPolicyTransport.encode(policy))
        XCTAssertEqual(WebFilterPolicyTransport.decode(pushedData), policy)

        let vendorConfiguration = try WebFilterPolicyTransport.vendorConfiguration(for: policy)
        let vendorData = try XCTUnwrap(vendorConfiguration[WebFilterPolicyTransport.policyDataKey] as? Data)
        XCTAssertEqual(pushedData, vendorData)
    }

    func testPolicyReplacementAcceptsNewerOrEqualRevision() {
        let current = makePolicy(enabled: true, rules: [])
        let sameRevision = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: false, revision: current.revision, blockedDomains: []),
            isDeviceBound: true
        )
        let newerRevision = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: true, revision: current.revision + 1, blockedDomains: []),
            isDeviceBound: true
        )

        XCTAssertTrue(WebFilterPolicyReplacement.shouldReplace(current: current, incoming: sameRevision))
        XCTAssertTrue(WebFilterPolicyReplacement.shouldReplace(current: current, incoming: newerRevision))
    }

    /// "时间到限网"的开始与结束**共用同一个 revision**——后端 applyWebLockdownOverride 是在
    /// 已生成的 DTO 上把 enabled 覆盖成 true，不碰 revision。所以守卫必须放行同 revision 的
    /// 替换（`>=` 而不是 `>`）：写成 `>` 会让限网结束的那份策略永远盖不过限网开始的那份，
    /// 孩子会一直被限下去。
    func testPolicyReplacementAllowsLockdownStartAndEndSharingOneRevision() {
        let lockdownStarted = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: true, revision: 4, blockedDomains: []),
            isDeviceBound: true
        )
        let lockdownEnded = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: false, revision: 4, blockedDomains: []),
            isDeviceBound: true
        )

        XCTAssertTrue(WebFilterPolicyReplacement.shouldReplace(current: lockdownStarted, incoming: lockdownEnded))
        XCTAssertTrue(WebFilterPolicyReplacement.shouldReplace(current: lockdownEnded, incoming: lockdownStarted))
    }

    /// 换家庭（解绑再绑）之后 revision 会从 0 重新开始：后端 unbindDevice 直接删掉设备行、
    /// 级联清空配置，webFilterRevision 默认 0。
    ///
    /// 这一条钉住的不是"守卫应该这么判"，而是**守卫绝不能套在系统配置那条通道上**：真套上去，
    /// 新家庭的策略会被上一个家庭留在 provider 内存里的高水位永久拒之门外。所以
    /// FilterDataProvider.applyPolicy 只对 source == .push 应用它，且 stopFilter 会把水位清零。
    func testRebindRestartsRevisionAndWouldBeRejectedByTheGuard() {
        let previousFamily = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: true, revision: 12, blockedDomains: []),
            isDeviceBound: true
        )
        let freshBinding = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: true, revision: 0, blockedDomains: []),
            isDeviceBound: true
        )

        XCTAssertFalse(
            WebFilterPolicyReplacement.shouldReplace(current: previousFamily, incoming: freshBinding),
            "守卫会挡住它——所以权威通道不能用守卫，否则换家庭后过滤器永久卡在旧策略上"
        )
    }

    /// 这是整个推送通道要挡的唯一情形：一份姗姗来迟的旧策略，绝不能把已经生效的新策略
    /// 挤掉。见 WebFilterPolicyReplacement 类注释里"两条路的到达顺序被打乱"那个场景。
    func testPolicyReplacementRejectsStaleRevision() {
        let current = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: true, revision: 9, blockedDomains: []),
            isDeviceBound: true
        )
        let stale = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(enabled: false, revision: 8, blockedDomains: []),
            isDeviceBound: true
        )

        XCTAssertFalse(WebFilterPolicyReplacement.shouldReplace(current: current, incoming: stale))
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
