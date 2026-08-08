import Foundation

struct WebFilterRule: Codable, Equatable {
    let domain: String
    let includeSubdomains: Bool
}

struct WebFilterConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var revision: Int64 = 0
    var blockedDomains: [WebFilterRule] = []
}

struct WebFilterPolicySnapshot: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let enabled: Bool
    let revision: Int64
    let blockedDomains: [WebFilterRule]
    let appliedAt: Date

    init(
        configuration: WebFilterConfiguration,
        isDeviceBound: Bool,
        appliedAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.enabled = isDeviceBound && configuration.enabled
        self.revision = configuration.revision
        self.blockedDomains = configuration.blockedDomains
        self.appliedAt = appliedAt
    }

    func blocks(hostname: String) -> Bool {
        guard enabled else { return false }
        let candidate = DomainName.normalize(hostname)
        return blockedDomains.contains { rule in
            let blocked = DomainName.normalize(rule.domain)
            if candidate == blocked {
                return true
            }
            return rule.includeSubdomains && candidate.hasSuffix(".\(blocked)")
        }
    }
}

enum DomainName {
    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingDot = trimmed.last == "." ? String(trimmed.dropLast()) : trimmed
        return withoutTrailingDot.lowercased()
    }
}

enum WebFilterPolicyTransport {
    static let policyDataKey = "BigDaddyWebFilterPolicyData"

    static func vendorConfiguration(for policy: WebFilterPolicySnapshot) throws -> [String: Any] {
        [policyDataKey: try encoder.encode(policy)]
    }

    static func policy(from vendorConfiguration: [String: Any]?) -> WebFilterPolicySnapshot? {
        guard let data = vendorConfiguration?[policyDataKey] as? Data else { return nil }
        return try? decoder.decode(WebFilterPolicySnapshot.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct WebFilterProviderAcknowledgement: Codable, Equatable {
    let appliedRevision: Int64
    let ruleCount: Int
    let blockedDomains: [WebFilterRule]
    let enforcementEnabled: Bool
    let appliedAt: Date
    /// **provider 进程自身的启动时刻**，与 appliedAt 是两件不同的事，别混用。
    ///
    /// appliedAt 每次重新应用策略都会刷新，因此它证明不了"provider 进程没重启过"——主 App
    /// 每次启动都会无条件重写一次 vendorConfiguration（见 WebFilterController.enableContentFilter），
    /// provider 收到 KVO 就 reloadPolicy 并发一份 appliedAt=now 的新回执。拿 appliedAt 去判断
    /// 进程存活，结论会**恒为否**。
    ///
    /// 这个字段只在 provider 进程构造时取一次值、此后再不改变，正好回答"这个 provider 进程
    /// 是什么时候起来的"——也就是 WebFilterController.extensionSurvivedGap 真正需要的信号。
    ///
    /// 可选是为了容忍版本错位：主 App 与系统扩展在更新期间可能短暂不同版本，旧 provider 发来
    /// 的回执没有这个字段，解码成 nil ⇒ 调用方按"问不出来"处理，而不是误判成"没存活"。
    let providerStartedAt: Date?

    init(policy: WebFilterPolicySnapshot, appliedAt: Date = Date(), providerStartedAt: Date? = nil) {
        appliedRevision = policy.revision
        ruleCount = policy.blockedDomains.count
        blockedDomains = policy.blockedDomains
        enforcementEnabled = policy.enabled
        self.appliedAt = appliedAt
        self.providerStartedAt = providerStartedAt
    }

    func confirms(_ policy: WebFilterPolicySnapshot) -> Bool {
        appliedRevision == policy.revision
            && ruleCount == policy.blockedDomains.count
            && blockedDomains == policy.blockedDomains
            && enforcementEnabled == policy.enabled
    }
}

// 回执此前经由 App Group 容器里的一个 json 传递，那条路在 root（provider）和登录用户
// （主 App）之间根本不通，已换成 XPC —— 原委见 WebFilterIPC.swift 顶部。

struct WebFilterStatusReport: Equatable {
    enum SystemExtensionState: String {
        case unavailable = "UNAVAILABLE"
        case activationRequested = "ACTIVATION_REQUESTED"
        case awaitingUserApproval = "AWAITING_USER_APPROVAL"
        case approved = "APPROVED"
        case restartRequired = "RESTART_REQUIRED"
        case failed = "FAILED"
        /// 扩展装好也批准过了，但系统里的内容过滤当前是关的——有人在「系统设置 →
        /// 登录项与扩展」或「网络 → 过滤器」里把它关掉了。必须和 unavailable
        /// （压根没装上）分开：前者是"被人关的、可以打开"，后者是"这台机器上没有"，
        /// 家长要做的事完全不同。
        case disabled = "DISABLED"
    }

    enum EnforcementState: String {
        case unknown = "UNKNOWN"
        case passThrough = "PASS_THROUGH"
        case enforcing = "ENFORCING"
    }

    let systemExtensionState: SystemExtensionState
    let enforcementState: EnforcementState
    let requestedRevision: Int64
    let appliedRevision: Int64
    let ruleCount: Int
    let lastAppliedAt: Date?
    let error: String?
}
