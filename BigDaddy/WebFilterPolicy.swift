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

    init(configuration: WebFilterConfiguration, isDeviceBound: Bool, appliedAt: Date = Date()) {
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

enum WebFilterSharedStore {
    static let appGroupInfoKey = "BigDaddyAppGroupIdentifier"
    static let policyFileName = "web-filter-policy.json"
    static let statusFileName = "web-filter-status.json"

    static func loadPolicy(bundle: Bundle = .main) throws -> WebFilterPolicySnapshot {
        let data = try Data(contentsOf: fileURL(named: policyFileName, bundle: bundle))
        return try decoder.decode(WebFilterPolicySnapshot.self, from: data)
    }

    static func savePolicy(_ policy: WebFilterPolicySnapshot, bundle: Bundle = .main) throws {
        let data = try encoder.encode(policy)
        try data.write(to: fileURL(named: policyFileName, bundle: bundle), options: .atomic)
    }

    static func loadStatus(bundle: Bundle = .main) throws -> WebFilterProviderStatus {
        let data = try Data(contentsOf: fileURL(named: statusFileName, bundle: bundle))
        return try decoder.decode(WebFilterProviderStatus.self, from: data)
    }

    static func saveStatus(_ status: WebFilterProviderStatus, bundle: Bundle = .main) throws {
        let data = try encoder.encode(status)
        try data.write(to: fileURL(named: statusFileName, bundle: bundle), options: .atomic)
    }

    private static func fileURL(named fileName: String, bundle: Bundle) throws -> URL {
        guard let appGroupIdentifier = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String else {
            throw WebFilterSharedStoreError.missingAppGroupIdentifier
        }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw WebFilterSharedStoreError.containerUnavailable(appGroupIdentifier)
        }
        return containerURL.appendingPathComponent(fileName)
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

enum WebFilterSharedStoreError: LocalizedError {
    case missingAppGroupIdentifier
    case containerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAppGroupIdentifier:
            return "BigDaddyAppGroupIdentifier is missing from Info.plist"
        case .containerUnavailable(let identifier):
            return "App Group container is unavailable: \(identifier)"
        }
    }
}

struct WebFilterProviderStatus: Codable, Equatable {
    enum SystemExtensionState: String, Codable {
        case approved = "APPROVED"
    }

    enum EnforcementState: String, Codable {
        case passThrough = "PASS_THROUGH"
        case enforcing = "ENFORCING"
    }

    let systemExtensionState: SystemExtensionState
    let enforcementState: EnforcementState
    let appliedRevision: Int64
    let ruleCount: Int
    let lastAppliedAt: Date

    func hasSamePolicyState(as other: WebFilterProviderStatus) -> Bool {
        systemExtensionState == other.systemExtensionState
            && enforcementState == other.enforcementState
            && appliedRevision == other.appliedRevision
            && ruleCount == other.ruleCount
    }
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
