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
    private var currentIsDeviceBound = false
    private var currentPolicy = WebFilterPolicySnapshot(
        configuration: WebFilterConfiguration(),
        isDeviceBound: false,
        appliedAt: Date(timeIntervalSince1970: 0)
    )
    /// 系统里那份内容过滤配置当前是否处于开启状态。
    ///
    /// nil = 还没成功回读过（启动早期），**不是** false：这两者在家长端要说完全不同的
    /// 两句话——"还在确认"和"已经被人关掉了"。凭一次都没读到就报后者，会在每次开机的
    /// 头几秒给家长一个假警报。
    private var systemFilterEnabled: Bool?
    private let providerConnection = WebFilterProviderConnection()

    private var filterConfigurationObserver: NSObjectProtocol?

    override init() {
        super.init()
        // 系统里那份过滤配置被**别人**改动时（孩子在系统设置里关掉网络扩展、或删掉
        // 「网络 → 过滤器」里那一条），NetworkExtension 会广播这条通知。这是我们能在
        // 第一时间发现"已生效"变成假话的唯一途径；只靠 60 秒轮询的话，家长会盯着一个
        // 绿色的"正在阻断"看上整整一分钟。
        filterConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .NEFilterConfigurationDidChange,
            object: NEFilterManager.shared(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshSystemFilterState()
            }
        }
    }

    deinit {
        if let filterConfigurationObserver {
            NotificationCenter.default.removeObserver(filterConfigurationObserver)
        }
    }

    private var shouldRunContentFilter: Bool {
        currentIsDeviceBound
    }

    /// 家长端"扩展被关掉了"这一条的判据。只有在扩展确实激活成功过之后，"系统里过滤
    /// 是关的"才等价于"有人关掉了它"；激活都还没走完时它当然是关的。
    var isSystemFilterDisabledExternally: Bool {
        shouldRunContentFilter && activationCompleted && systemFilterEnabled == false
    }

    func statusReport(requestedRevision: Int64) async -> WebFilterStatusReport {
        var systemExtensionState: WebFilterStatusReport.SystemExtensionState
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

        func report(
            _ extensionState: WebFilterStatusReport.SystemExtensionState,
            _ enforcement: WebFilterStatusReport.EnforcementState
        ) -> WebFilterStatusReport {
            WebFilterStatusReport(
                systemExtensionState: extensionState,
                enforcementState: enforcement,
                requestedRevision: requestedRevision,
                appliedRevision: 0,
                ruleCount: 0,
                lastAppliedAt: nil,
                error: error
            )
        }

        guard shouldRunContentFilter else {
            return report(systemExtensionState, .passThrough)
        }

        switch systemFilterEnabled {
        case .none:
            return report(systemExtensionState, .unknown)
        case .some(false):
            // 已经批准过、家长也要它跑，但系统里的过滤是关的 —— 被人从系统设置里关掉了。
            // 只在"其余一切正常"时才覆盖成 disabled：activation 本身失败/待批准这些更
            // 靠前的原因更具体，盖掉它们等于把家长指向错误的修复动作。
            if systemExtensionState == .approved {
                systemExtensionState = .disabled
            }
            return report(systemExtensionState, .passThrough)
        case .some(true):
            break
        }

        let policy = currentPolicy
        guard let acknowledgement = await providerConnection.acknowledgement(),
              acknowledgement.confirms(policy)
        else {
            return report(systemExtensionState, .unknown)
        }

        return WebFilterStatusReport(
            systemExtensionState: systemExtensionState,
            enforcementState: acknowledgement.enforcementEnabled ? .enforcing : .passThrough,
            requestedRevision: requestedRevision,
            appliedRevision: acknowledgement.appliedRevision,
            ruleCount: acknowledgement.ruleCount,
            lastAppliedAt: acknowledgement.appliedAt,
            error: error
        )
    }

    /// 回读系统里那份过滤配置的真实开关状态。
    ///
    /// 没有这一步的话，孩子在「系统设置 → 登录项与扩展」里把网络扩展一关，客户端内存
    /// 里的"已启用"仍然是 true、回执也仍然对得上，于是继续向家长上报"已生效，正在阻断"
    /// —— 家长看着一个绿色的"正在阻断"，实际一条都没拦。这是比 UI 文案严重得多的一种
    /// 错误，所以每次上报之前都要回读一次，而不是只在自己改配置时更新。
    func refreshSystemFilterState() async {
        // 自己正在改配置时不插队：那条路径结束时会写下更准的值，这里读到的多半是中间态。
        guard !configurationUpdateInFlight else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NEFilterManager.shared().loadFromPreferences { [weak self] error in
                Task { @MainActor [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }
                    // 读失败保持上一次的判断：一次偶发的 IPC 失败不该被翻译成
                    // "扩展被关掉了"推给家长。
                    guard error == nil else { return }
                    let manager = NEFilterManager.shared()
                    self.updateSystemFilterEnabled(manager.isEnabled && self.isBigDaddyFilter(manager))
                }
            }
        }
    }

    private func updateSystemFilterEnabled(_ enabled: Bool) {
        guard systemFilterEnabled != enabled else { return }
        let hadValue = systemFilterEnabled != nil
        systemFilterEnabled = enabled
        if hadValue && !enabled && shouldRunContentFilter && activationCompleted {
            AuditLog.record("WEB_FILTER_DISABLED_EXTERNALLY")
        }
        notifyStateChanged()
    }

    func synchronize(configuration: WebFilterConfiguration, isDeviceBound: Bool) {
        currentIsDeviceBound = isDeviceBound
        currentPolicy = WebFilterPolicySnapshot(
            configuration: configuration,
            isDeviceBound: isDeviceBound
        )

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
            if shouldRunContentFilter {
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
        if shouldRunContentFilter {
            ensureInfrastructure()
        } else {
            disableContentFilter()
        }
    }

    private func ensureInfrastructure() {
        guard shouldRunContentFilter else {
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
        guard shouldRunContentFilter else {
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

                guard self.shouldRunContentFilter else {
                    self.finishConfigurationUpdate()
                    self.configurationUpdatePending = false
                    self.disableContentFilter()
                    return
                }

                let providerConfiguration = NEFilterProviderConfiguration()
                providerConfiguration.filterSockets = true
                providerConfiguration.filterDataProviderBundleIdentifier = Self.extensionBundleIdentifier
                providerConfiguration.organization = "BigDaddy"
                do {
                    providerConfiguration.vendorConfiguration = try WebFilterPolicyTransport.vendorConfiguration(for: self.currentPolicy)
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
                        guard self.shouldRunContentFilter else {
                            self.configurationUpdatePending = false
                            self.disableContentFilter()
                            return
                        }
                        self.systemFilterEnabled = true
                        self.state = .configurationEnabled
                        AuditLog.record("WEB_FILTER_CONFIGURATION_SAVED policyEnabled=\(self.currentPolicy.enabled)")
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

                let currentlyEnabled = manager.isEnabled && self.isBigDaddyFilter(manager)
                self.systemFilterEnabled = currentlyEnabled
                if !currentlyEnabled {
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
        systemFilterEnabled = false
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
