import XCTest
@testable import BigDaddy

/// 这一组测试守的是同一件事：**限制打开的那一秒，浏览器里已经开着的受限网站要立刻断掉**。
///
/// 原始故障是"孩子先在 Chrome 里开着 youtube，家长再打开限制，cmd+R 和新标签还能继续看，
/// 要好几分钟才失效"。根因有两半，这里只测得到第二半，第一半在
/// WebFilterController.shouldRunContentFilter 的注释里：
///
/// 1. 过滤器当时根本没在跑（限制关闭时整个关掉），已存在的 socket 对 provider 不可见；
/// 2. 就算跑着，也得在策略翻转时对这些**旧流**做出正确的掐断判定——就是下面这些用例。
final class WebFilterFlowDispositionTests: XCTestCase {

    /// 核心回归：透传期间跟踪下来的受限连接，必须在策略翻成启用的那一刻被判死。
    func testFlowTrackedWhilePassThroughIsTerminatedOncePolicyEnables() {
        let hostname = "www.youtube.com"
        let passThrough = makePolicy(enabled: false, rules: [
            WebFilterRule(domain: "youtube.com", includeSubdomains: true)
        ])
        let enforcing = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "youtube.com", includeSubdomains: true)
        ])

        XCTAssertFalse(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: hostname, isLikelyQUIC: false, under: passThrough),
            "限制还没打开，什么都不该掐"
        )
        XCTAssertTrue(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: hostname, isLikelyQUIC: false, under: enforcing),
            "限制一打开，这条早就建立的连接必须当场断掉——它正是 cmd+R 和新标签复用的那一条"
        )
    }

    func testUnrelatedHostSurvivesPolicyChange() {
        let enforcing = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "youtube.com", includeSubdomains: true)
        ])

        XCTAssertFalse(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: "www.apple.com", isLikelyQUIC: false, under: enforcing)
        )
    }

    /// 认不出主机名的 QUIC：透传期间不掐（那时掐它没有任何理由，只会白白打断别的程序），
    /// 启用之后必须掐——否则浏览器会一直复用这条加密握手的通道绕过限制。
    func testUnidentifiedQUICIsTerminatedOnlyWhileEnforcing() {
        let rules = [WebFilterRule(domain: "youtube.com", includeSubdomains: true)]

        XCTAssertFalse(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: nil, isLikelyQUIC: true, under: makePolicy(enabled: false, rules: rules))
        )
        XCTAssertTrue(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: nil, isLikelyQUIC: true, under: makePolicy(enabled: true, rules: rules))
        )
    }

    /// "认不出来一律放行"这条纪律的边界：非 QUIC 且认不出主机名的流，哪怕正在限网也不掐。
    /// 误拦会毫无征兆地掐断孩子电脑上任意一个程序的网络。
    func testUnidentifiedNonQUICFlowIsNeverTerminated() {
        let enforcing = makePolicy(enabled: true, rules: [
            WebFilterRule(domain: "youtube.com", includeSubdomains: true)
        ])

        XCTAssertFalse(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: nil, isLikelyQUIC: false, under: enforcing)
        )
    }

    /// 黑名单被家长清空（限制仍开着）时，已经跟踪的流不该再被掐——包括那些认不出主机名的
    /// QUIC。这一条现在由 policy.enabled 之外的规则表为空来保证，属于容易在重构里丢掉的
    /// 行为，所以钉住。
    func testEmptyRuleListTerminatesNothingByHostname() {
        let enforcing = makePolicy(enabled: true, rules: [])

        XCTAssertFalse(
            WebFilterFlowDisposition.shouldTerminate(
                hostname: "www.youtube.com", isLikelyQUIC: false, under: enforcing)
        )
    }

    private func makePolicy(enabled: Bool, rules: [WebFilterRule]) -> WebFilterPolicySnapshot {
        WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(
                enabled: enabled,
                revision: 12,
                blockedDomains: rules
            ),
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
