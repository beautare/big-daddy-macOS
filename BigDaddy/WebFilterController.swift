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
    var onStateChanged: (() -> Void)?

    private var activationSubmitted = false
    private var activationCompleted = false
    private var configurationUpdateInFlight = false
    private var configurationUpdatePending = false
    private var currentConfiguration = WebFilterConfiguration()
    private var currentIsDeviceBound = false
    private var contentFilterEnabled = false
    private var lastConfigurationAppliedAt: Date?

    private var desiredFilterEnabled: Bool {
        currentIsDeviceBound && currentConfiguration.enabled
    }

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

        guard desiredFilterEnabled else {
            return WebFilterStatusReport(
                systemExtensionState: systemExtensionState,
                enforcementState: .passThrough,
                requestedRevision: requestedRevision,
                appliedRevision: requestedRevision,
                ruleCount: 0,
                lastAppliedAt: nil,
                error: error
            )
        }

        guard contentFilterEnabled else {
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
            enforcementState: .enforcing,
            requestedRevision: requestedRevision,
            appliedRevision: requestedRevision,
            ruleCount: currentConfiguration.blockedDomains.count,
            lastAppliedAt: lastConfigurationAppliedAt,
            error: error
        )
    }

    func synchronize(configuration: WebFilterConfiguration, isDeviceBound: Bool) {
        currentConfiguration = configuration
        currentIsDeviceBound = isDeviceBound

        applyDesiredFilterState()
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
        let nsError = error as NSError
        let message = "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
        Task { @MainActor [weak self] in
            self?.handleActivationFailed(message)
        }
    }

    private func handleUserApprovalRequired() {
        state = .awaitingUserApproval
        AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_AWAITING_APPROVAL")
        notifyStateChanged()
    }

    private func handleActivationFinished(_ result: OSSystemExtensionRequest.Result) {
        activationSubmitted = false
        activationCompleted = true
        switch result {
        case .completed:
            state = .approved
            AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_APPROVED")
            if desiredFilterEnabled {
                enableContentFilter()
            } else {
                disableContentFilter()
            }
        case .willCompleteAfterReboot:
            state = .restartRequired
            AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_RESTART_REQUIRED")
            notifyStateChanged()
        @unknown default:
            state = .failed("Unknown system extension activation result")
            notifyStateChanged()
        }
    }

    private func handleActivationFailed(_ message: String) {
        activationSubmitted = false
        state = .failed(message)
        AuditLog.record("WEB_FILTER_SYSTEM_EXTENSION_FAILED error=\(message)")
        notifyStateChanged()
    }

    private func applyDesiredFilterState() {
        if desiredFilterEnabled {
            ensureInfrastructure()
        } else {
            disableContentFilter()
        }
    }

    private func ensureInfrastructure() {
        guard desiredFilterEnabled else {
            disableContentFilter()
            return
        }

        if activationCompleted {
            enableContentFilter()
            return
        }
        guard !activationSubmitted else { return }

        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(Self.extensionBundleIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            state = .unavailable
            NSLog("BigDaddy: embedded web filter system extension is unavailable")
            notifyStateChanged()
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
        notifyStateChanged()
    }

    private func enableContentFilter() {
        guard desiredFilterEnabled else {
            disableContentFilter()
            return
        }
        guard !configurationUpdateInFlight else {
            configurationUpdatePending = true
            return
        }
        configurationUpdateInFlight = true
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.finishConfigurationUpdate()
                    self.state = .failed(error.localizedDescription)
                    AuditLog.record("WEB_FILTER_CONFIGURATION_LOAD_FAILED error=\(error.localizedDescription)")
                    self.notifyStateChanged()
                    self.applyPendingConfigurationUpdateIfNeeded()
                    return
                }

                guard self.desiredFilterEnabled else {
                    self.finishConfigurationUpdate()
                    self.configurationUpdatePending = false
                    self.disableContentFilter()
                    return
                }

                let providerConfiguration = NEFilterProviderConfiguration()
                providerConfiguration.filterSockets = true
                providerConfiguration.filterDataProviderBundleIdentifier = Self.extensionBundleIdentifier
                providerConfiguration.organization = "BigDaddy"
                let policy = WebFilterPolicySnapshot(
                    configuration: self.currentConfiguration,
                    isDeviceBound: self.currentIsDeviceBound
                )
                do {
                    providerConfiguration.vendorConfiguration = try WebFilterPolicyTransport.vendorConfiguration(for: policy)
                } catch {
                    self.finishConfigurationUpdate()
                    self.state = .failed(error.localizedDescription)
                    self.notifyStateChanged()
                    self.applyPendingConfigurationUpdateIfNeeded()
                    return
                }

                manager.localizedDescription = "BigDaddy Web Filter"
                manager.providerConfiguration = providerConfiguration
                manager.grade = .firewall
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error {
                            self.finishConfigurationUpdate()
                            self.state = .failed(error.localizedDescription)
                            AuditLog.record("WEB_FILTER_CONFIGURATION_SAVE_FAILED error=\(error.localizedDescription)")
                            self.notifyStateChanged()
                            self.applyPendingConfigurationUpdateIfNeeded()
                            return
                        }
                        self.finishConfigurationUpdate()
                        guard self.desiredFilterEnabled else {
                            self.configurationUpdatePending = false
                            self.disableContentFilter()
                            return
                        }
                        self.contentFilterEnabled = true
                        self.lastConfigurationAppliedAt = Date()
                        self.state = .configurationEnabled
                        AuditLog.record("WEB_FILTER_CONFIGURATION_ENABLED")
                        self.notifyStateChanged()
                        self.applyPendingConfigurationUpdateIfNeeded()
                    }
                }
            }
        }
    }

    private func disableContentFilter() {
        guard !configurationUpdateInFlight else {
            configurationUpdatePending = true
            return
        }
        configurationUpdateInFlight = true
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.finishConfigurationUpdate()
                    self.state = .failed(error.localizedDescription)
                    AuditLog.record("WEB_FILTER_CONFIGURATION_LOAD_FAILED error=\(error.localizedDescription)")
                    self.notifyStateChanged()
                    self.applyPendingConfigurationUpdateIfNeeded()
                    return
                }

                let isBigDaddyFilter = self.isBigDaddyFilter(manager)
                self.contentFilterEnabled = manager.isEnabled && isBigDaddyFilter
                if !self.contentFilterEnabled {
                    self.finishConfigurationUpdate()
                    self.markContentFilterDisabled()
                    self.applyPendingConfigurationUpdateIfNeeded()
                    return
                }

                manager.isEnabled = false
                manager.saveToPreferences { error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error {
                            self.finishConfigurationUpdate()
                            self.state = .failed(error.localizedDescription)
                            AuditLog.record("WEB_FILTER_CONFIGURATION_DISABLE_FAILED error=\(error.localizedDescription)")
                            self.notifyStateChanged()
                            self.applyPendingConfigurationUpdateIfNeeded()
                            return
                        }
                        self.finishConfigurationUpdate()
                        self.markContentFilterDisabled()
                        AuditLog.record("WEB_FILTER_CONFIGURATION_DISABLED")
                        self.applyPendingConfigurationUpdateIfNeeded()
                    }
                }
            }
        }
    }

    private func markContentFilterDisabled() {
        contentFilterEnabled = false
        switch state {
        case .configurationEnabled:
            state = .approved
        case .failed:
            state = activationCompleted ? .approved : .unavailable
        default:
            break
        }
        notifyStateChanged()
    }

    private func finishConfigurationUpdate() {
        configurationUpdateInFlight = false
    }

    private func applyPendingConfigurationUpdateIfNeeded() {
        if configurationUpdatePending {
            configurationUpdatePending = false
            applyDesiredFilterState()
        }
    }

    private func isBigDaddyFilter(_ manager: NEFilterManager) -> Bool {
        manager.grade == .firewall
            && manager.providerConfiguration?.filterDataProviderBundleIdentifier == Self.extensionBundleIdentifier
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }
}
