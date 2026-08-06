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
    let policyID: UUID
    let enabled: Bool
    let revision: Int64
    let blockedDomains: [WebFilterRule]
    let appliedAt: Date

    init(
        configuration: WebFilterConfiguration,
        isDeviceBound: Bool,
        policyID: UUID = UUID(),
        appliedAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.policyID = policyID
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
    let policyID: UUID
    let appliedRevision: Int64
    let ruleCount: Int
    let blockedDomains: [WebFilterRule]
    let enforcementEnabled: Bool
    let appliedAt: Date

    init(policy: WebFilterPolicySnapshot, appliedAt: Date = Date()) {
        policyID = policy.policyID
        appliedRevision = policy.revision
        ruleCount = policy.blockedDomains.count
        blockedDomains = policy.blockedDomains
        enforcementEnabled = policy.enabled
        self.appliedAt = appliedAt
    }

    func confirms(_ policy: WebFilterPolicySnapshot) -> Bool {
        policyID == policy.policyID
            && appliedRevision == policy.revision
            && ruleCount == policy.blockedDomains.count
            && blockedDomains == policy.blockedDomains
            && enforcementEnabled == policy.enabled
    }
}

enum WebFilterProviderAcknowledgementStore {
    private static let appGroupInfoKey = "BigDaddyAppGroupIdentifier"
    private static let fileName = "web-filter-provider-acknowledgement.json"

    static func load(bundle: Bundle = .main) -> WebFilterProviderAcknowledgement? {
        guard let fileURL = fileURL(bundle: bundle), let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? decoder.decode(WebFilterProviderAcknowledgement.self, from: data)
    }

    static func save(_ acknowledgement: WebFilterProviderAcknowledgement, bundle: Bundle = .main) throws {
        guard let fileURL = fileURL(bundle: bundle) else {
            throw WebFilterProviderAcknowledgementStoreError.containerUnavailable
        }
        try encoder.encode(acknowledgement).write(to: fileURL, options: .atomic)
    }

    private static func fileURL(bundle: Bundle) -> URL? {
        guard let identifier = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String else {
            return nil
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum WebFilterProviderAcknowledgementStoreError: Error {
    case containerUnavailable
}

struct WebFilterStatusReport: Equatable {
    enum SystemExtensionState: String {
        case unavailable = "UNAVAILABLE"
        case activationRequested = "ACTIVATION_REQUESTED"
        case awaitingUserApproval = "AWAITING_USER_APPROVAL"
        case approved = "APPROVED"
        case restartRequired = "RESTART_REQUIRED"
        case failed = "FAILED"
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
