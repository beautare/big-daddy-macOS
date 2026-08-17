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
    private var currentPolicy = WebFilterPolicySnapshot(
        configuration: WebFilterConfiguration(),
        isDeviceBound: false,
        appliedAt: Date(timeIntervalSince1970: 0)
    )
    /// 设备是否已绑定。currentPolicy 里只留下了 `isDeviceBound && enabled` 的结果，
    /// 这两者现在必须分开：过滤器**开不开**看绑定，**拦不拦**看策略。见
    /// shouldRunContentFilter。
    private var isDeviceBound = false
    /// 系统里那份内容过滤配置当前是否处于开启状态。
    ///
    /// nil = 还没成功回读过（启动早期），**不是** false：这两者在家长端要说完全不同的
    /// 两句话——"还在确认"和"已经被人关掉了"。凭一次都没读到就报后者，会在每次开机的
    /// 头几秒给家长一个假警报。
    private var systemFilterEnabled: Bool?
    /// 检测到"过滤被外部关掉"之后已经自动重开过几次。见 repairSystemFilterIfPossible。
    private var filterRepairAttempts = 0
    private static let maxFilterRepairAttempts = 3
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

    /// 系统里那份内容过滤配置该不该处于开启状态——**只看设备有没有绑定**，不看家长此刻
    /// 有没有打开网站限制。"过滤器开着"和"正在拦截"是两件必须分开的事，后者见
    /// isEnforcementIntended。
    ///
    /// 这一条曾经写成 currentPolicy.enabled（限制关着就把过滤器整个关掉），理由是别让
    /// 从不使用这项功能的家庭平白经历一次系统弹窗。代价直到实测才暴露出来：
    /// NEFilterDataProvider **只收得到自己启动之后新建的流**，系统不会把已经存在的 socket
    /// 补送给它，也没有任何 API 能事后枚举或掐断它们。于是"孩子先在 Chrome 里开着
    /// YouTube，家长再打开限制"这个最常见的场景里，那条已经建立的连接对过滤器完全不存在：
    /// cmd+R 和新标签都复用它，一直要等浏览器自己因空闲超时拆掉连接（几分钟）才第一次
    /// 撞上过滤器。FilterDataProvider 里那套"放行也保持挂载、策略变严时补一刀"的设计，
    /// 在这个场景里根本没有机会执行。
    ///
    /// 所以过滤器从绑定那一刻起就一直开着，限制关闭期间以透传模式运行（policy.enabled
    /// 为 false ⇒ blocks() 恒为 false，全部放行但保持跟踪）。限制打开时，那些连接早就
    /// 在 trackedFlows 里、主机名也已解析好，reloadPolicy 当场就能把它们掐断。
    ///
    /// 代价是首次启用会弹一次系统的"允许过滤网络内容"。这被放在绑定那一刻——与
    /// requestSystemExtensionApprovalEagerly 索取系统扩展批准同一时机，不额外制造一个
    /// 新的打扰点。
    private var shouldRunContentFilter: Bool {
        isDeviceBound
    }

    /// 家长此刻**要不要**拦。所有面向家长的状态（徽章、"已生效"、"被关掉了"）都以它为准，
    /// 不能用 shouldRunContentFilter 代替：后者在限制关闭期间同样为真，拿它去驱动展示，
    /// 会在家长根本没开限制的时候报出"正在阻断"或"限制已被关闭"。
    private var isEnforcementIntended: Bool {
        currentPolicy.enabled
    }

    /// 家长端"扩展被关掉了"这一条的判据。只有在扩展确实激活成功过之后，"系统里过滤
    /// 是关的"才等价于"有人关掉了它"；激活都还没走完时它当然是关的。
    ///
    /// 判据是 isEnforcementIntended 而不是 shouldRunContentFilter：限制关闭期间过滤器
    /// 虽然也该开着（为了预热跟踪），但那时被人关掉并不构成一次"防线失守"，不该向家长
    /// 报警——自动恢复照常进行（见 repairSystemFilterIfPossible），只是不出现在 UI 上。
    var isSystemFilterDisabledExternally: Bool {
        isEnforcementIntended && activationCompleted && systemFilterEnabled == false
    }

    /// 网站访问是否正被限制——菜单栏右上角"受限"徽章用的信号。
    ///
    /// 不区分这个 true 是家长自己长期开着的黑名单造成的，还是"时间到限网"临时加的：
    /// 两者对客户端呈现为同一个 policy.enabled=true（见 intelli-sight
    /// BigDaddyService#applyWebLockdownOverride），调用方不需要、也不应该知道是谁触发的。
    ///
    /// 黑名单为空时即使 enabled=true 也不算"正在限制"——那种情况下什么都拦不住，
    /// 显示"受限"会是一句谎言（与仪表盘 currentlyWebFilterOnEmpty 同一条纪律）。
    ///
    /// 注意这里只反映"策略意图"，不等于"扩展真的在拦"：扩展被人从系统设置里关掉时
    /// （isSystemFilterDisabledExternally），这个属性依然会是 true。调用方（AppDelegate）
    /// 必须优先处理"扩展本身有问题"这一类信号，再决定要不要显示这个徽章——否则会在
    /// 防线实际失守的那一刻，图标却说"正在限制"。
    var isRestrictingWebAccess: Bool {
        isEnforcementIntended && !currentPolicy.blockedDomains.isEmpty
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

        // 家长没开限制时就是透传，不必再往下问系统和扩展。这里刻意用 isEnforcementIntended
        // 而不是 shouldRunContentFilter：后者在限制关闭期间也为真（过滤器一直开着做预热
        // 跟踪），拿它当门槛会让"没开限制"的设备也走进下面的 .disabled / .unknown 分支，
        // 家长端凭空多出一行红字。
        guard isEnforcementIntended else {
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

    /// 「上次运行没有正常结束」发生时，内容过滤系统扩展是否曾在整段空窗期里连续存活。
    ///
    /// 系统扩展由 systemextensionsd 独立管理，进程生命周期与主 App 不同——孩子在活动监视器
    /// 强杀 BigDaddy 主进程杀不到它。所以只要能证明"这个 provider 进程从空窗期之前一直活到
    /// 现在"，就等于证明了本机全程通电在线，这次异常终止更可能是主进程被单独杀掉，而不是
    /// 整机断电/重启/断网。
    ///
    /// 判据是 providerStartedAt（provider 进程构造时取一次、此后不变），**不是** appliedAt。
    /// 用 appliedAt 会得到一个恒为 false 的假信号：主 App 每次启动都无条件重写一次
    /// vendorConfiguration（见 enableContentFilter），provider 收到 KVO 就 reloadPolicy 并
    /// 发一份 appliedAt=now 的新回执，而本方法恰恰是在主 App 启动早期调用的。
    ///
    /// 这是一个**事后取证**信号，不是实时判据：主进程一旦被杀就什么都报不出去了，这里能做的
    /// 只是在下次启动时，问一问"有没有别的独立进程能证明机器其实一直开着"。
    ///
    /// 返回 nil 表示"问不出来"（没开网站过滤、扩展当前不可达、还从未应用过任何策略、或对端
    /// 是不带 providerStartedAt 的旧版扩展），调用方不能把 nil 当结论用；只有明确的
    /// true/false 才能拿去说话。
    func extensionSurvivedGap(since gapStartedAt: Date) async -> Bool? {
        guard let acknowledgement = await providerConnection.acknowledgement(),
              let providerStartedAt = acknowledgement.providerStartedAt
        else { return nil }
        return providerStartedAt < gapStartedAt
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
        if enabled {
            // 确实恢复了，重试预算归零，下次再被关掉还能再自愈三次
            filterRepairAttempts = 0
        } else if hadValue && shouldRunContentFilter && activationCompleted {
            // enforcing=false 表示这次是在"限制关着、过滤器只做预热跟踪"的期间被关掉的：
            // 家长端不会因此报警（见 isSystemFilterDisabledExternally），但自动恢复照做——
            // 否则下次家长打开限制时，预热跟踪是空的，又会退回到那几分钟的滞后。
            AuditLog.record("WEB_FILTER_DISABLED_EXTERNALLY enforcing=\(isEnforcementIntended)")
            repairSystemFilterIfPossible()
        }
        notifyStateChanged()
    }

    /// 被关掉之后自己重新打开。
    ///
    /// 这是监护类产品的本分：孩子（或任何坐在这台机器前的人）在系统设置里把网络过滤
    /// 关掉之后，客户端不能只是如实上报一句"已被关闭"然后干等——那等于把开关交到了
    /// 被监护的一方手里。NEFilterManager 那份配置归本 App 所有，把 isEnabled 重新置
    /// true 并保存不需要任何用户交互。
    ///
    /// 这条恢复路径此前整个不存在：`updateSystemFilterEnabled` 只观察不修复，而
    /// `enableContentFilter()` 只在配置变更或激活完成时才被调用。于是"在系统设置里把
    /// 网络扩展关掉再打开"会让客户端永久停在"已被关闭"——菜单里那条「点此恢复」也只是
    /// 打开系统设置，并不真的恢复什么。等于任何人只要拨一次那个开关，就能把整个网站
    /// 访问限制永久关掉。
    ///
    /// 必须有次数上限：如果系统扩展本身被停用、或 macOS 因为别的原因拒绝保存，无限重试
    /// 会变成一个"每次配置变更都自我触发"的死循环。用完预算就停手，如实上报 DISABLED，
    /// 由家长按引导去系统设置处理。
    private func repairSystemFilterIfPossible() {
        guard shouldRunContentFilter, activationCompleted else { return }
        guard filterRepairAttempts < Self.maxFilterRepairAttempts else {
            AuditLog.record("WEB_FILTER_REPAIR_GAVE_UP attempts=\(filterRepairAttempts)")
            return
        }
        filterRepairAttempts += 1
        AuditLog.record("WEB_FILTER_REPAIR_ATTEMPT attempt=\(filterRepairAttempts)")
        enableContentFilter()
    }

    /// 家长在菜单/「关于」窗口里点「重新开启」时调用。
    ///
    /// 与自动恢复共用同一条路径，区别只是重置重试预算：这是一次明确的人类意图，
    /// 不该被之前那几次自动重试用掉的额度挡住。
    func repairSystemFilterNow() {
        filterRepairAttempts = 0
        applyDesiredFilterState()
    }

    func synchronize(configuration: WebFilterConfiguration, isDeviceBound: Bool) {
        self.isDeviceBound = isDeviceBound
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
        submitActivationRequestIfNeeded()
    }

    /// 绑定阶段（AppDelegate.checkAndRequestPermissions）提前索取系统扩展批准的入口。
    ///
    /// 与 ensureInfrastructure 的关键区别：**不看 shouldRunContentFilter**。系统扩展的
    /// 批准（出现在「登录项与扩展」列表里、必要时弹出批准提示）和"是否真的启用过滤"是
    /// 两件事——本方法只负责前者，把它提前到绑定那一刻，不必等家长日后远程打开网站
    /// 访问限制才发生（同 AppDelegate 里屏幕录制/辅助功能的一次性预热逻辑）。是否真正
    /// 启用过滤仍然完全由 shouldRunContentFilter 决定：批准完成后 handleActivationFinished
    /// 会照常按当时的 shouldRunContentFilter 决定 enableContentFilter 还是
    /// disableContentFilter，本方法不改变这一点。
    func requestSystemExtensionApprovalEagerly() {
        guard !activationCompleted else { return }
        submitActivationRequestIfNeeded()
    }

    private func submitActivationRequestIfNeeded() {
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

        // 抄近路：下面这条 NEFilterManager.saveToPreferences() → provider 的
        // filterConfiguration KVO 管线是系统自己的配置分发路径，实测把新策略真正送到
        // 一个已经在跑的 provider 进程可能要一两分钟——跟"家长打开限制、孩子的浏览器
        // 应该立刻被掐断"差得远。主 App 手上此刻已经有这份策略，没理由干等，直接经
        // 同一个 mach service 推一份过去（见 FilterDataProvider.applyPolicy 的注释）。
        //
        // provider 不在线时（还没激活、或系统扩展被人关掉）这次推送单纯失败，无副作用——
        // 下面走 NEFilterManager 的那条路仍然是权威的、扛得住 provider 重启的持久化路径，
        // 推送只是它的加速通道，不是替代品。
        let policyToPush = currentPolicy
        Task { [providerConnection] in
            _ = await providerConnection.pushPolicy(policyToPush)
        }

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
