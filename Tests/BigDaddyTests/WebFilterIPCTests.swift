import XCTest
@testable import BigDaddy

/// 回执通道的字符串推导。
///
/// 值得为这几行写测试，是因为它们错了不会有任何报错：mach 服务名两端对不上时 XPC 只是
/// 静默连不上，过滤照常工作，家长端安静地永远停在"策略同步中"——正是这次要修的那个
/// bug 的形状。package.sh 在打包时会拿 machServiceName 的结果和扩展 Info.plist 里的
/// NEMachServiceName 逐字比对，这里守的是等号另一边。
final class WebFilterIPCTests: XCTestCase {
    private let signedGroup = "L2GSNW7RA2.group.vip.bigdaddy.shared"
    /// 本地 CODESIGN_IDENTITY="-" 的调试构建：package.sh 里 TEAM_IDENTIFIER_PREFIX 为空
    private let unsignedGroup = "group.vip.bigdaddy.shared"

    func testMachServiceNameMatchesPackagingConvention() {
        XCTAssertEqual(
            WebFilterIPC.machServiceName(appGroupIdentifier: signedGroup),
            "L2GSNW7RA2.group.vip.bigdaddy.shared.BigDaddyWebFilter"
        )
        XCTAssertEqual(
            WebFilterIPC.machServiceName(appGroupIdentifier: unsignedGroup),
            "group.vip.bigdaddy.shared.BigDaddyWebFilter"
        )
    }

    func testMachServiceNameAlwaysStartsWithTheAppGroup() {
        // NetworkExtension 的硬性要求：不满足的话系统压根不会替扩展注册这个 mach 服务
        for group in [signedGroup, unsignedGroup] {
            XCTAssertTrue(WebFilterIPC.machServiceName(appGroupIdentifier: group).hasPrefix(group))
        }
    }

    func testTeamIdentifierIsExtractedOnlyFromSignedGroups() {
        XCTAssertEqual(WebFilterIPC.teamIdentifier(appGroupIdentifier: signedGroup), "L2GSNW7RA2")
        XCTAssertNil(WebFilterIPC.teamIdentifier(appGroupIdentifier: unsignedGroup))
    }

    func testUnsignedBuildsGetNoCodeSigningRequirement() {
        // 本地调试构建两端都没签名，强加签名要求会让它们互相拒绝，
        // 于是本地永远复现不出正常状态——那正好是最需要能跑通的场景。
        XCTAssertNil(WebFilterIPC.codeSigningRequirement(appGroupIdentifier: unsignedGroup))
    }

    func testSignedBuildsRequirePeerFromSameTeam() {
        XCTAssertEqual(
            WebFilterIPC.codeSigningRequirement(appGroupIdentifier: signedGroup),
            "anchor apple generic and certificate leaf[subject.OU] = \"L2GSNW7RA2\""
        )
    }

    func testAcknowledgementSurvivesTheWire() {
        let policy = WebFilterPolicySnapshot(
            configuration: WebFilterConfiguration(
                enabled: true,
                revision: 6,
                blockedDomains: [WebFilterRule(domain: "youtube.com", includeSubdomains: true)]
            ),
            isDeviceBound: true,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // appliedAt 显式给一个整秒值：编解码走的是 .iso8601，它只到秒，用 Date() 的话
        // 亚秒部分会在往返中被抹掉，等值断言会以一条"两个看起来一模一样的时间不相等"
        // 的报错失败。抹掉本身无害（confirms 不看这个字段，家长端也只显示到秒），
        // 但值得在这里写死，免得日后有人把它当成 bug 重新查一遍。
        let acknowledgement = WebFilterProviderAcknowledgement(
            policy: policy,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_123)
        )

        let encoded = WebFilterAcknowledgementCodec.encode(acknowledgement)
        XCTAssertNotNil(encoded)
        let decoded = encoded.flatMap(WebFilterAcknowledgementCodec.decode)

        XCTAssertEqual(decoded, acknowledgement)
        // 过完这一圈还得认得出自己确认的是哪份策略——家长端"实际版本/已生效"整列都靠它
        XCTAssertTrue(decoded?.confirms(policy) == true)
    }
}
