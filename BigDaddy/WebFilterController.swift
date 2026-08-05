import Foundation
@preconcurrency import NetworkExtension
@preconcurrency import SystemExtensions

@MainActor
final class WebFilterController: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionBundleIdentifier = "vip.bigdaddy.monitor.web-filter-extension"

    enum State: Equatable {
        case unavailable
        case activationRequested
        case awaitingUserApproval
        case approved
        case configurationEnabled
        case restartRequired
        case failed(String)
    }

    private(set) var state: State = .unavailable
    private var activationSubmitted = false
    private var activationCompleted = false
    private var configurationUpdateInFlight = false

    func statusReport(requestedRevision: Int64) -> WebFilterStatusReport {
        let systemExtensionState: WebFilterStatusReport.SystemExtensionState
        let error: String?
        switch state {
        case .unavailable:
            systemExtensionState = .unavailable
            error = nil
        case .activationRequested:
            systemExtensionState = .activationRequested
            error = nil
        case .awaitingUserApproval:
            systemExtensionState = .awaitingUserApproval
            error = nil
        case .approved, .configurationEnabled:
            systemExtensionState = .approved
            error = nil
        case .restartRequired:
            systemExtensionState = .restartRequired
            error = nil
        case .failed(let message):
            systemExtensionState = .failed
            error = message
        }

        guard let providerStatus = try? WebFilterSharedStore.loadStatus() else {
            return WebFilterStatusReport(
                systemExtensionState: systemExtensionState,
                enforcementState: .unknown,
                requestedRevision: requestedRevision,
                appliedRevision: 0,
                ruleCount: 0,
                lastAppliedAt: nil,
                error: error
            )
        }

        return WebFilterStatusReport(
            systemExtensionState: systemExtensionState,
            enforcementState: providerStatus.enforcementState == .enforcing ? .enforcing : .passThrough,
            requestedRevision: requestedRevision,
            appliedRevision: providerStatus.appliedRevision,
            ruleCount: providerStatus.ruleCount,
            lastAppliedAt: providerStatus.lastAppliedAt,
            error: error
        )
    }

    func synchronize(configuration: WebFilterConfiguration, isDeviceBound: Bool) {
        let policy = WebFilterPolicySnapshot(
            configuration: configuration,
            isDeviceBound: isDeviceBound
        )
        do {
            try WebFilterSharedStore.savePolicy(policy)
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("BigDaddy: web filter policy could not be stored: \(error.localizedDescription)")
            return
        }

        guard isDeviceBound else { return }
        ensureInfrastructure()
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor [weak self] in
            self?.handleUserApprovalRequired()
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor [weak self] in
            self?.handleActivationFinished(result)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleActivationFailed(message)
        }
    }

    private func handleUserApprovalRequired() {
        state = .awaitingUserApproval
        AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_AWAITING_APPROVAL")
    }

    private func handleActivationFinished(_ result: OSSystemExtensionRequest.Result) {
        activationSubmitted = false
        activationCompleted = true
        switch result {
        case .completed:
            state = .approved
            AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_APPROVED")
            enableContentFilter()
        case .willCompleteAfterReboot:
            state = .restartRequired
            AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_RESTART_REQUIRED")
        @unknown default:
            state = .failed("Unknown system extension activation result")
        }
    }

    private func handleActivationFailed(_ message: String) {
        activationSubmitted = false
        state = .failed(message)
        AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_FAILED error=\(message)")
    }

    private func ensureInfrastructure() {
        if activationCompleted {
            enableContentFilter()
            return
        }
        guard !activationSubmitted else { return }

        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("BigDaddyWebFilter.systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            state = .unavailable
            NSLog("BigDaddy: embedded web filter system extension is unavailable")
            return
        }

        activationSubmitted = true
        state = .activationRequested
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func enableContentFilter() {
        guard !configurationUpdateInFlight else { return }
        configurationUpdateInFlight = true
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.configurationUpdateInFlight = false
                    self.state = .failed(error.localizedDescription)
                    AuditLog.record("WEB_FILTER_CONFIGURATION_LOAD_FAILED error=\(error.localizedDescription)")
                    return
                }

                if manager.isEnabled,
                   manager.grade == .firewall,
                   let existingConfiguration = manager.providerConfiguration,
                   existingConfiguration.filterSockets,
                   existingConfiguration.filterDataProviderBundleIdentifier == Self.extensionBundleIdentifier {
                    self.configurationUpdateInFlight = false
                    self.state = .configurationEnabled
                    return
                }

                let providerConfiguration = NEFilterProviderConfiguration()
                providerConfiguration.filterSockets = true
                providerConfiguration.filterDataProviderBundleIdentifier = Self.extensionBundleIdentifier
                providerConfiguration.organization = "BigDaddy"

                manager.localizedDescription = "BigDaddy Web Filter"
                manager.providerConfiguration = providerConfiguration
                manager.grade = .firewall
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.configurationUpdateInFlight = false
                        if let error {
                            self.state = .failed(error.localizedDescription)
                            AuditLog.record("WEB_FILTER_CONFIGURATION_SAVE_FAILED error=\(error.localizedDescription)")
                            return
                        }
                        self.state = .configurationEnabled
                        AuditLog.record("WEB_FILTER_CONFIGURATION_ENABLED")
                    }
                }
            }
        }
    }
}
