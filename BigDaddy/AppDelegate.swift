import AppKit
import CryptoKit
import Security
import ApplicationServices
import Sparkle

enum Localization {
    static var isChinese: Bool {
        isChinese(for: Locale.preferredLanguages.first)
    }

    static func isChinese(for preferredLanguage: String?) -> Bool {
        preferredLanguage?.lowercased().hasPrefix("zh") ?? false
    }

    static func string(zh: String, en: String) -> String {
        string(zh: zh, en: en, preferredLanguage: Locale.preferredLanguages.first)
    }

    static func string(zh: String, en: String, preferredLanguage: String?) -> String {
        guard isChinese(for: preferredLanguage) else { return en }
        guard usesTraditionalChinese(for: preferredLanguage) else { return zh }

        return zh.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? zh
    }

    private static func usesTraditionalChinese(for preferredLanguage: String?) -> Bool {
        guard let language = preferredLanguage?.lowercased() else { return false }
        return language.contains("hant")
            || language.contains("-tw")
            || language.contains("-hk")
            || language.contains("-mo")
    }
}

/// 绑定码弹窗的 runModal 是从主 actor 任务内部调起的，这种弹窗期间主队列不排空
/// （并非所有 modal 都如此——从菜单动作直接调起的弹窗主队列照常排空，机制见
/// showDeviceBindCode 注释），后台任务的结果不能用 Task { @MainActor } /
/// DispatchQueue.main 送回界面；改为写入这个带锁的信箱，由 selector 计时器的
/// tick（modal 期间照常触发）在主线程取走并应用。
/// 必须放在 AppDelegate 外部：嵌套类型会继承 @MainActor 隔离，后台任务就没法写入了。
final class BindTokenMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func put(_ token: String) {
        lock.lock()
        value = token
        lock.unlock()
    }

    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate, NSWindowDelegate, SPUUpdaterDelegate {
    private var statusItem: NSStatusItem?
    private let client = BigDaddyClient()
    private let webFilterController = WebFilterController()
    private var screenshotTimer: Timer?
    private var heartbeatTimer: Timer?
    private var commandTimer: Timer?
    private var idleActivityTimer: Timer?
    private let idleActivityPollInterval: TimeInterval = 5
    private var configTimer: Timer?
    private var webFilterStatusReportTask: Task<Void, Never>?
    private var webFilterStatusRetryCount = 0
    private static let maxWebFilterStatusRetries = 5
    /// 屏幕录制权限的授予/撤回都发生在系统设置里，没有公开的变更通知 API 可订阅，只能
    /// 轮询；这个定时器让菜单栏图标（盾牌旁的感叹号 ⇄ 圆点徽章）在用户刚授权/撤权后近乎实时地跟上，
    /// 不用等到下一次远端配置轮询（60 秒）。见 refreshIconIfPermissionChanged。
    private var permissionPollTimer: Timer?
    /// 上一次观测到的屏幕录制权限状态，nil 表示"还没观测过"或"截图关闭、不关心"。
    private var lastKnownScreenRecordingPermission: Bool?
    /// 自动路径（定时/命令）因缺权限静默失败时，是否已经提醒过用户"可能需要重启"——
    /// 避免同一段"截图开着但缺权限"的连续期间里，每次失败都弹一遍通知。截图开关每次
    /// 翻转（见 pollConfigForChildVisibility）都会复位，让下一段新的"开着但缺权限"
    /// 期间还能再提醒一次。
    private var missingPermissionNoticeShown = false
    /// 上一次就"浏览器自动化权限"提醒过的时间，按浏览器 bundle id 分区。
    ///
    /// 按浏览器分区：自动化是"发起方 × 目标"逐对授权的，孩子换个浏览器就是一份全新的、
    /// 同样需要引导的授权，不能因为提醒过 Chrome 就对 Safari 闭嘴。
    ///
    /// 记时间而不是"提醒过没有"：这个客户端设计上常年不退出（开机自启 + 无人值守），
    /// 一个进程生命周期内只提醒一次，实际效果就是家长错过第一次通知之后再也收不到第二次。
    /// 改成按 automationNoticeInterval 衰减，既不会每分钟心跳都骚扰，也不会永久闭嘴。
    private var automationNoticeShownAt: [String: Date] = [:]
    /// 同一个浏览器两次"网址未授权"提醒之间的最小间隔
    private static let automationNoticeInterval: TimeInterval = 24 * 60 * 60
    /// 绑定自检弹窗里最多列几个浏览器（NSAlert 的 accessoryView 不滚动，见 createPermissionCheckerView）
    private static let maxBrowserPermissionRows = 5
    /// 是否有浏览器处于"自动化权限被拒"状态——决定"关于"面板里要不要出现引导入口。
    /// 记 bundle id 而不是布尔，是为了在面板文案里说清楚是哪个浏览器。
    /// 这份集合有六个写入点（探测被拒、探测恢复、批量自检、重置授权……），所以同步给
    /// client 的动作挂在 didSet 上而不是逐个调用点手写——漏掉任何一处，家长端的开通
    /// 引导就会长期显示一个陈旧的"浏览器网址读取"状态。
    private var automationDeniedBundleIDs: Set<String> = [] {
        didSet { client.automationBlocked = !automationDeniedBundleIDs.isEmpty }
    }
    private var screenshotFlashTimer: Timer?
    private var countdownTimer: Timer?
    private var countdownSeconds = 300
    private var digitLabels: [NSTextField] = []
    private var countdownLabel: NSTextField?
    /// 绑定码到期后的静默刷新是否正在进行，防止倒计时 tick 在网络慢时重复发起
    private var bindTokenRefreshing = false
    /// 刷新结果信箱：后台任务写入、倒计时 tick 在主线程取走（见 bindCountdownTick）
    private let bindTokenMailbox = BindTokenMailbox()
    private var exitDigitFields: [NSTextField] = []
    /// 与 exitDigitFields 一一对应，记录每格"最后一次合法数字输入"，用于在用户
    /// 输入非数字字符时把格子还原回原值（见 controlTextDidChange）。
    private var exitDigitPreviousValues: [String] = []
    private var exitCountdownLabel: NSTextField?
    /// 必须持有引用，否则 DispatchSourceSignal 会被提前释放、信号监听失效
    private var signalSources: [DispatchSourceSignal] = []
    /// 凭据失效弹窗每次运行只弹一次（register 会在扫码绑定等多处重复调用），菜单警示项常驻
    private var credentialsAlertShown = false
    /// "去批准网络扩展"的主动弹窗是否已经弹过。每进入一次待批准状态弹一次，离开该
    /// 状态时复位——见 promptWebFilterApprovalIfNeeded。
    private var webFilterApprovalPromptShown = false
    /// 菜单打开触发的绑定状态同步做节流，避免频繁点开图标时打网络风暴
    private var lastBindingSyncAt: Date = .distantPast
    /// 绑定检测快轮询任务（展示绑定码/二维码后启动的一段高频探测），持有引用以便取消
    private var bindDetectionTask: Task<Void, Never>?
    /// 后台已静默下载完毕、等着安装的更新版本号（非空即代表"有更新就绪"），驱动下拉
    /// 菜单和"关于"面板里的提示文案。
    private var pendingUpdateVersion: String?
    /// 与之配套的"立即安装并重启"动作：Sparkle 把它以闭包形式交给我们（见
    /// updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)），什么时候调用
    /// 就什么时候装好并重启。Sparkle 2.3 起该闭包允许重复调用。
    private var pendingUpdateInstall: (() -> Void)?
    /// 等设备空闲、伺机静默安装的轮询计时器（见 scheduleIdleInstallCheck），只在有
    /// 待装更新期间存活。
    private var updateIdleInstallTimer: Timer?
    /// "关于"窗口（自绘 NSWindow，见 showAboutWindow）当前是否已打开，再次点击菜单项时
    /// 先关掉旧的再重建，避免残留一个数据已过期的旧窗口。
    /// 家长已经点过"前往系统设置授权"，正处在"去设置里开开关 → 回来重启生效"这段
    /// 两步流程的中间。
    ///
    /// 为什么需要显式记这个状态、而不是靠查权限：屏幕录制权限是
    /// `CGPreflightScreenCaptureAccess()`，它在**本进程内有缓存**——家长在系统设置里
    /// 把开关打开之后，我们这个进程再怎么查都还是 false，直到重启。也就是说"是否已经
    /// 授权"这件事我们在代码里根本看不见，只能看见"家长有没有点过那颗按钮"。
    ///
    /// 这个状态一旦为 true，两处 UI 都会改变：「关于」窗口把第 2 步（重启生效）提成
    /// 主按钮，菜单栏一级菜单也会多出一条同样的提醒。见 showAboutWindow / rebuildMenu。
    private var awaitingScreenRecordingGrant = false

    private weak var aboutWindow: NSWindow?
    /// 与"关于"窗口里按钮的 tag 一一对应，点击时按下标取出对应动作执行（见 aboutActionTapped）。
    private var aboutWindowActions: [() -> Void] = []
    /// "关于"窗口里"下次截屏"行的剩余时间字段，每秒被 aboutCountdownTimer 刷新；仅在
    /// 渲染了该行（截图已开启）时非空，窗口关闭时清空（见 windowWillClose）。
    private weak var aboutCountdownField: NSTextField?
    /// 驱动上面字段每秒倒计时的定时器，只在"关于"窗口开着期间存活。
    private var aboutCountdownTimer: Timer?
    /// "关于"窗口里"时间约定"行的剩余时间字段，与 aboutCountdownField 共用同一个
    /// aboutCountdownTimer 每秒刷新；仅在渲染了该行（有进行中的约定）时非空。
    private weak var aboutTimeSessionField: NSTextField?

    // MARK: - 时间约定（家长设定的可用时长）

    /// 下拉旗帜管理器，懒加载（首次需要展示时才按显示器创建 NSPanel）。
    private var timeFlag: TimeAgreementFlag?
    /// 驱动倒计时/里程碑检查的 1 秒定时器，仅在有进行中的约定时存活。
    private var timeSessionTimer: Timer?
    /// 本地单调时钟截止点：`ProcessInfo.systemUptime`（收到这份会话快照那一刻） +
    /// remainingSeconds。用单调时钟而不是墙钟——孩子改系统时间不影响倒计时；服务端仍是
    /// 唯一权威，每次 syncTimeSessionState 都会用服务端最新值重新定锚这个值。
    private var timeSessionDeadline: TimeInterval?
    /// 当前正在跟踪的会话 id，用于识别"变了"（新开/被替换/被中断/到点清空）。
    private var trackedTimeSessionId: String?
    /// 本地倒计时已经判过到点、但服务端还没确认的那个会话 id。
    ///
    /// 服务端的到点扫描器每 30 秒跑一次，在"本地归零"到"服务端确认"之间存在一个最长
    /// 30 秒的窗口。这段时间里 GET /client/config 仍会返回**这个会话本身**（status 还是
    /// ACTIVE），只是 remainingSeconds 已被服务端算成 0（见后端 remainingSeconds：
    /// endsAt 已过但 status 未翻转时返回 0）。必须能识别出"这个会话我本地已经处理完了"，
    /// 否则窗口内任何一次配置轮询都会把它当成一个全新会话重新开始（见 syncTimeSessionState）。
    private var locallyExpiredSessionId: String?
    /// 里程碑触发记录，换一个新会话（sessionId 变化）时清空重来。
    private var timeSessionMilestonesFired: Set<TimeSessionMilestone> = []
    /// 菜单里"⏳ 剩余 …"这一条的引用，供 menuWillOpen 每次打开菜单时刷新文字，
    /// 不必为了刷新一个数字就整个 rebuildMenu()。
    private var timeSessionMenuItem: NSMenuItem?
    /// 菜单当前是否展开着（menuWillOpen ⇄ menuDidClose）。
    private var menuIsOpen = false
    /// 菜单展开期间收到的重建请求，等菜单关掉再补做一次（原因见 rebuildMenu 的注释）。
    private var menuRebuildPending = false
    /// 菜单展开期间每秒刷新剩余时间的定时器，关菜单即停。
    private var openMenuTickTimer: Timer?
    /// 家长去系统设置开辅助功能期间的状态轮询，授权到手或超时即停（见 startAccessibilityGrantWatch）。
    private var accessibilityWatchTimer: Timer?

    private enum TimeSessionMilestone: Hashable {
        case started, halfway, fiveMinutes, oneMinute, thirtySeconds
    }
    // startingUpdater: true 后立即开始按 SUScheduledCheckInterval（Info.plist，当前 4 小时）
    // 后台检查；SUEnableAutomaticChecks/SUAutomaticallyUpdate 已在 Info.plist 里直接置为
    // true，跳过 Sparkle 首次运行询问用户的对话框，检查与静默下载都无条件自动进行。
    //
    // updaterDelegate 指向 self 是"下载好之后弹窗问用户"的唯一入口。这里曾经挂的是
    // userDriverDelegate（SPUStandardUserDriverDelegate 的 gentle reminders 那套接口），
    // 那段代码从未生效过：SUAutomaticallyUpdate=true 时 Sparkle 选的是
    // SPUAutomaticUpdateDriver，它的 showingUpdate 恒为 NO、从头到尾不调用 user driver，
    // 于是 standardUserDriverShouldHandleShowingScheduledUpdate /
    // standardUserDriverWillHandleShowingUpdate 在后台检查里一次都不会被回调，
    // 更新只会悄悄下载、等 App 下次退出时静默装上，用户全程无感。真正会被回调的是
    // SPUUpdaterDelegate 的 updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)。
    //
    // userDriverDelegate 留 nil：用户手动点"检查更新…"照常走 Sparkle 的标准界面。
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("BigDaddy: applicationDidFinishLaunching started")
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("BigDaddy: StatusItem created")
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        print("BigDaddy: signal handlers installed")
        client.prepareRuntime()
        print("BigDaddy: runtime prepared")
        client.startNetworkMonitoring()
        print("BigDaddy: network monitoring started")
        webFilterController.onStateChanged = { [weak self] in
            guard let self else { return }
            self.scheduleWebFilterStatusReport()
            self.rebuildMenu()
            self.updateStatusItemAppearance()
            // 异步派发而不是直接调：这个回调本身是从 WebFilterController 的状态迁移里
            // 发出来的，而 promptWebFilterApprovalIfNeeded 会 runModal 停住主 runloop，
            // 在状态迁移中途停下来等用户点按钮容易把后续回调堆在一起重入。
            DispatchQueue.main.async { [weak self] in
                self?.promptWebFilterApprovalIfNeeded()
            }
        }
        webFilterController.synchronize(
            configuration: client.config.webFilter,
            isDeviceBound: client.config.bound
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWebFilterConfigChanged),
            name: BigDaddyClient.webFilterConfigChangedNotification,
            object: client
        )
        scheduleWebFilterStatusReport()
        #if !DEBUG
        // DEBUG（Xcode 直接运行 / swift build）的可执行文件不在任何 .app bundle 里，
        // 没有 Info.plist，Sparkle 找不到 SUFeedURL/SUPublicEDKey 必然启动失败、弹出
        // "Unable to Check For Updates"。只有 scripts/package.sh 打包出的 Release .app
        // 才带 Info.plist，这里跳过 DEBUG 下的自动初始化，避免每次启动都弹一次失败框；
        // 用户在"关于"窗口手动点"检查更新…"时仍会走到 checkForUpdates() 触发同一个
        // lazy var，DEBUG 下点了照样会看到这个框（预期内，因为手动点击就是想验证结果）。
        _ = updaterController // 触发 lazy 初始化，启动 Sparkle 后台更新检查
        print("BigDaddy: Sparkle updater started")
        #else
        print("BigDaddy: Sparkle updater skipped in DEBUG build")
        #endif
        LaunchAtLoginController.syncWithPreference()
        print("BigDaddy: launch agent checked")
        // 菜单栏图标随"截图是否开启"状态变化，孩子端始终可见当前是否处于可截屏状态
        updateStatusItemAppearance()
        print("BigDaddy: StatusItem appearance set")
        schedulePermissionPollTimer()
        // 监听"实际发生截图"事件，触发孩子端即时可见提示
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenshotSent),
            name: BigDaddyClient.screenshotSentNotification, object: nil
        )
        // 监听"自动路径因缺权限静默放弃截图"事件，节流一次性提醒用户去"关于"重启
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenshotMissingPermission),
            name: BigDaddyClient.screenshotMissingPermissionNotification, object: nil
        )
        // 监听"前台浏览器因自动化权限拿不到 URL"事件，按浏览器节流后引导授权
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBrowserAutomationBlocked),
            name: BigDaddyClient.browserAutomationBlockedNotification, object: nil
        )
        // 时间约定的门铃：命令轮询里一旦发现 SYNC_TIME_SESSION 就已经 refreshConfig 过，
        // 这里只需要把最新状态同步进旗帜/菜单/计时器，把感知延迟从 60 秒配置轮询压到
        // 命令轮询的 0~30 秒。
        NotificationCenter.default.addObserver(
            forName: BigDaddyClient.timeSessionSyncedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncTimeSessionState() }
        }
        installPowerAndSessionObservers()
        rebuildMenu()
        print("BigDaddy: menu rebuilt")
        presentFirstRunDisclosureIfNeeded()
        scheduleTimers()
        print("BigDaddy: timers scheduled")
        Task {
            print("BigDaddy: async task background started")
            let configRefreshResult = await client.refreshConfig()
            let configChanged = configRefreshResult.changed
            print("BigDaddy: async task background heartbeat sending started")
            // 本次启动永远是 START 事件；如果检测到上次异常终止，通过
            // previousCrashAt 字段"如实补报"，而不是把这次正常启动本身
            // 标记成 FORCE_KILL（那样会让后端把重启误判成刚刚发生的强杀）。
            //
            // 时间戳的取走与清空都在 sendHeartbeat 内部完成（送达或写入补发队列都算已持久
            // 记录），这里不再"仅在心跳成功时清空"：离线启动时那样会让它留在内存里，被本次
            // 会话往后的每一条心跳反复带上，库里堆出一串 previous_crash_at 相同的记录。
            if let crashedAt = client.detectedPreviousCrash {
                AuditLog.record("PREVIOUS_CRASH_DETECTED at=\(ISO8601DateFormatter().string(from: crashedAt))")
            }
            await client.sendHeartbeat(event: .start)
            // 如果配置有变化，额外发送 CONFIG_UPDATED 事件
            if configChanged {
                await client.sendHeartbeat(event: .configUpdated)
            }
            await MainActor.run {
                print("BigDaddy: async task background completed, updating UI configChanged: \(configChanged)")
                if configChanged {
                    scheduleTimers()
                }
                rebuildMenu()
                presentCredentialsAlertIfNeeded()
                // 已绑定的机器上装了新浏览器时，这里补一次预热——每个 bundle id 一生
                // 只会走到一次，已经预热过的启动不会有任何动静（见方法注释）
                warmAutomationConsentIfNeeded()
                // 冷启动时如果家长设定的约定还在进行中（客户端在中途被重启/崩溃后拉起），
                // 这里负责发现它并补上旗帜/计时器——trackedTimeSessionId 此刻恒为 nil，
                // 只要 config.timeSession 非空就会被 syncTimeSessionState 判定为"新会话"。
                syncTimeSessionState()
            }
        }
    }

    /// 后端在 register 时报告本机 secret 与存档不一致（设备已绑定、拒绝换钥）。
    /// 此状态下心跳/命令/截图上传全部验签失败、家长端显示离线，必须当面说清恢复路径。
    private func presentCredentialsAlertIfNeeded() {
        guard client.credentialsInvalid, !credentialsAlertShown else { return }
        credentialsAlertShown = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localization.string(zh: "设备凭据失效", en: "Device Credentials Invalid")
        alert.informativeText = Localization.string(
            zh: "本机的设备密钥与服务器存档不一致（通常发生在重装或更换客户端构建之后），守护数据暂时无法上报，家长端会显示设备离线。\n\n恢复方法：请家长在仪表盘中解绑本设备，然后重启客户端并重新绑定。",
            en: "This Mac's device key no longer matches the server record (usually after reinstalling or switching client builds). Guardian data cannot be reported and the dashboard will show this device as offline.\n\nTo recover: unbind this device on the parent dashboard, then restart the client and bind again."
        )
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // SHUTDOWN 心跳只在 quitWithPassword 里校验通过后同步发送一次；这里不再重复
        // 调用 sendShutdownSync()，否则用户点击"安全退出"时会先在 quitWithPassword
        // 里发一次，随后 NSApp.terminate(nil) 触发本方法时又发一次，导致家长端收到
        // 两条 SHUTDOWN 记录。若进程是被信号杀死（非本方法触发的正常退出），由
        // installSignalHandlers 里的 FORCE_KILL 上报负责如实反映。
    }

    @objc private func onWebFilterConfigChanged() {
        webFilterController.synchronize(
            configuration: client.config.webFilter,
            isDeviceBound: client.config.bound
        )
        webFilterStatusRetryCount = 0
        scheduleWebFilterStatusReport()
    }

    private func scheduleWebFilterStatusReport() {
        webFilterStatusReportTask?.cancel()
        webFilterStatusReportTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await self.reportWebFilterStatus()
        }
    }

    private func reportWebFilterStatus() async {
        guard client.config.bound else { return }
        // 先回读系统里那份过滤配置的真实开关，再组装上报。顺序不能反：孩子刚在系统
        // 设置里把网络扩展关掉时，客户端内存里还是"已启用"，先报后读就等于把这一分钟
        // 的"其实没在拦"上报成了"正在阻断"。
        await webFilterController.refreshSystemFilterState()
        let report = await webFilterController.statusReport(
            requestedRevision: client.config.webFilter.revision
        )
        await client.reportWebFilterStatus(report)
        guard report.systemExtensionState == .approved,
              report.enforcementState == .unknown,
              webFilterStatusRetryCount < Self.maxWebFilterStatusRetries
        else {
            return
        }
        webFilterStatusRetryCount += 1
        scheduleWebFilterStatusReport()
    }

    /// 重建整张菜单。
    ///
    /// **菜单展开期间一律不重建**，改为记一笔待办、等 menuDidClose 再补做。
    ///
    /// 这不是性能顾虑，而是"菜单里的剩余时间时走时不走"那个 bug 的正身：本方法每次都
    /// `NSMenu()` 造一张全新的菜单并赋回 statusItem，而屏幕上正显示着的是**旧**那张——
    /// AppKit 在 tracking 期间会把它一直留在屏幕上。赋值之后 timeSessionMenuItem 指向了
    /// 新菜单里那条离屏的项，于是每秒 tick 忠实地刷新着一条谁也看不见的文字，孩子/家长
    /// 眼前那条就此冻结。而重建的触发点（menuWillOpen 里那次配置同步、浏览器授权状态
    /// 变化等）本身是零星发生的，于是表现成"有时候不倒数，关掉重开又好了，过一会又不走"。
    private func rebuildMenu() {
        guard !menuIsOpen else {
            menuRebuildPending = true
            // 菜单内容整体延后，但那条剩余时间是纯本地计算、就地改 title 即可，
            // 不必让家长盯着一个停住的数字等到菜单关闭。
            refreshTimeSessionMenuItemText()
            return
        }
        menuRebuildPending = false
        let menu = NSMenu()
        menu.delegate = self

        // 凭据失效警示常驻菜单顶部：此状态下心跳/命令全部验签失败，设备在家长端
        // 显示离线，必须引导解绑后重新绑定，而不是让守护无声失效
        if client.credentialsInvalid {
            let credentialItem = NSMenuItem(
                title: Localization.string(
                    zh: "⚠️ 设备凭据失效：请家长在仪表盘解绑后重新绑定",
                    en: "⚠️ Device credentials invalid: unbind on dashboard, then re-bind"
                ),
                action: nil, keyEquivalent: ""
            )
            credentialItem.isEnabled = false
            menu.addItem(credentialItem)
            menu.addItem(.separator())
        }

        if client.config.bound {
            let statusItem = NSMenuItem(
                title: Localization.string(zh: "状态: 已受保护", en: "Status: Protected"),
                action: nil, keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(.separator())
        } else {
            let statusItem = NSMenuItem(
                title: Localization.string(zh: "⚠️ 状态: 尚未绑定家长账号 (未开启守护)", en: "⚠️ Status: Unbound (Guardianship Pending)"),
                action: nil, keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let hintItem = NSMenuItem(
                title: Localization.string(zh: "💡 未绑定时仅进行最基础登记，不采集行为明细", en: "💡 Unbound: Coarse registry only, no activity details logged"),
                action: nil, keyEquivalent: ""
            )
            hintItem.isEnabled = false
            menu.addItem(hintItem)

            // 装错机器的出口。家长在自己的电脑上浏览官网时，"下载"的默认语义就是"下到这台
            // 机器"，所以把 BigDaddy 装到家长自己的 Mac 上是个高频误操作——而它一旦被绑定，
            // 纠错就得走"解绑（永久删除该设备全部历史）→ 换机器重装"这条贵的路。未绑定态
            // 是拦下这个错误最省事的时机，所以这条提示只在这里出现。
            let wrongMacItem = NSMenuItem(
                title: Localization.string(
                    zh: "🙋 我是家长，这是我自己的电脑——该怎么办？",
                    en: "🙋 I'm the parent and this is my own Mac — now what?"
                ),
                action: #selector(showWrongMacHelp), keyEquivalent: ""
            )
            menu.addItem(wrongMacItem)

            // 之前拆成"显示本机绑定码"和"输入家长给的码"两条平行菜单项，两者都叫"绑定"，
            // 孩子分不清该点哪个。改成一条入口，点开后再用弹窗把两种方式说清楚。
            menu.addItem(NSMenuItem(
                title: Localization.string(zh: "⚡️ 绑定本设备…", en: "⚡️ Bind This Mac…"),
                action: #selector(showBindEntry), keyEquivalent: "b"
            ))
            menu.addItem(.separator())
        }

        // 时间约定：有进行中的约定时常驻展示剩余时间，紧跟在绑定状态之后——这是家长
        // "现在正在发生"的一件事，比下面的浏览器警示/关于/开机自启这些次要项更该被
        // 第一眼看到。菜单每次打开都会刷新这一条的文字（见 menuWillOpen），这里只
        // 负责渲染初始文案。
        //
        // 判据特意用 trackedTimeSessionId/timeSessionDeadline（客户端自己已经权威更新的
        // 本地状态），而不是直接查 client.config.timeSession：本地倒计时归零那一刻，
        // handleTimeSessionReachedZero 已经把这两者清空、旗帜也已经在闪烁，但服务端的
        // 30 秒扫描器还没确认到点，client.config.timeSession 这时仍是"看起来还在进行"的
        // 陈旧快照——直接用它会让这一项在旗帜已经闪烁提醒时，还显示着一个不会再变的
        // 陈旧非零读数，与旗帜的状态互相矛盾。
        if let session = client.config.timeSession, let deadline = timeSessionDeadline,
           trackedTimeSessionId == session.sessionId {
            let remaining = max(0, Int((deadline - ProcessInfo.processInfo.systemUptime).rounded(.up)))
            let item = NSMenuItem(
                title: Self.timeSessionMenuTitle(remaining: remaining, grantedSeconds: session.grantedSeconds),
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            timeSessionMenuItem = item
        } else {
            timeSessionMenuItem = nil
        }

        if let webFilterTitle = webFilterMenuTitle(for: webFilterAttention) {
            menu.addItem(NSMenuItem(
                title: webFilterTitle,
                action: #selector(openWebFilterAuthorization), keyEquivalent: ""
            ))
            menu.addItem(.separator())
        }

        // 屏幕录制"就差最后一步"的兜底提醒。
        //
        // 家长点过"前往系统设置授权"、在设置里开完开关之后，还剩一步重启才生效。那一步
        // 的按钮在「关于」窗口里（现在会一直开着等他回来），但家长完全可能顺手把窗口关了、
        // 或者在设置里绕了一圈就忘了这回事。菜单栏图标此刻还挂着警示徽章，他点开菜单
        // 想搞清楚是怎么回事——这条就得在这儿等着，而且是一点就完事的。
        //
        // 少了这条，最坏情况就是家长的原始抱怨："我明明授权了，怎么还是警示图标？"
        if client.config.bound && client.config.screenshotEnabled
            && awaitingScreenRecordingGrant && !checkScreenRecordingPermission() {
            menu.addItem(NSMenuItem(
                title: Localization.string(
                    zh: "✅ 已在设置里授权？点此重启生效",
                    en: "✅ Granted in Settings? Restart to Apply"
                ),
                action: #selector(promptRestartForScreenRecording), keyEquivalent: ""
            ))
            menu.addItem(.separator())
        }

        // 辅助功能未授权：和下面那条网址授权一样是"可点即修"的待办，但后果更重——
        // 非浏览器窗口的标题、以及 Firefox 系浏览器的地址栏都只能从辅助功能树里读，
        // 缺了它家长端看到的是一片没有标题、没有链接的空记录。
        //
        // 为什么绑定时明明拦过一次、这里还要再来一条：那道闸只在**绑定那一刻**生效
        // （checkAndRequestPermissions），而这个权限完全可能在绑定之后失效——家长在
        // 系统设置里手滑关掉、系统升级后 TCC 记录重置、或者（开发期最常见）客户端
        // 重新签名后 macOS 认不出这是同一个 App。一旦失效，此前**整个客户端里没有
        // 任何一个入口**能把它重新打开：菜单里没有、「关于」窗口里也没有，只有重新
        // 绑定一次才会再弹那道闸。这正是"Firefox 一直显示无网址、却无从下手"的成因。
        if client.config.bound && !AXIsProcessTrustedWithOptions(nil) {
            menu.addItem(NSMenuItem(
                title: Localization.string(
                    zh: "⚠️ 辅助功能未授权 · 点此修复",
                    en: "⚠️ Accessibility access off · Fix it"
                ),
                action: #selector(promptAccessibilityPermission), keyEquivalent: ""
            ))
            menu.addItem(.separator())
        }

        // 浏览器网址未授权：这是一条**可点即修**的待办，必须留在一级菜单。
        //
        // 之前它只存在于两个地方：一次性的本机通知（错过就没了）和「关于 BigDaddy…」
        // 里的一颗按钮（要先知道去那儿翻）。结果是家长端一直显示"网址未授权"，而机器
        // 跟前的人根本不知道有个开关等着点。放在这里，图标上的 ⚠️ 也就有了落点。
        if client.config.bound && !automationDeniedBundleIDs.isEmpty {
            menu.addItem(NSMenuItem(
                title: Localization.string(
                    zh: "⚠️ 浏览器网址未授权 · 点此修复",
                    en: "⚠️ Browser URL access off · Fix it"
                ),
                action: #selector(promptAutomationPermission), keyEquivalent: ""
            ))
            menu.addItem(.separator())
        }

        // 有更新已经静默下载好、正等着装：安装策略是"等设备空闲再静默装上"（见
        // scheduleIdleInstallCheck），不弹任何询问框——但空闲之前这段时间不能什么都
        // 不露，否则孩子/家长完全无从知道客户端正处在"随时可能重启一次"的状态。这条
        // 是唯一常驻可见的信号，跟"关于"窗口里那个高亮按钮是同一件事的两个入口。
        // 点击 = 明确的"现在就装"，跳过等空闲这一步。
        if let version = pendingUpdateVersion {
            menu.addItem(NSMenuItem(
                title: Localization.string(
                    zh: "⬆️ 新版本 \(version) 待安装 · 点此立即安装",
                    en: "⬆️ Update \(version) ready · Click to install now"
                ),
                action: #selector(installPendingUpdate), keyEquivalent: ""
            ))
            menu.addItem(.separator())
        }

        // 版本/配置摘要/心跳/截图倒计时/守护说明/导出记录/检查更新——这些都是次要或
        // 只读信息，收进"关于 BigDaddy"里，一级菜单只留状态和最关键的操作。
        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "关于 BigDaddy…", en: "About BigDaddy…"),
            action: #selector(showAboutWindow), keyEquivalent: ""
        ))

        // 默认开启，孩子可自行开启（无需验证）；关闭是敏感操作，需要家长验证码才能
        // 生效，见 toggleLaunchAtLogin/disableLaunchAtLoginWithVerification。
        let launchAtLoginItem = NSMenuItem(
            title: Localization.string(zh: "开机自动启动", en: "Start at Login"),
            action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        launchAtLoginItem.state = LaunchAtLoginPreference.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "安全退出", en: "Secure Exit"),
            action: #selector(quitWithPassword), keyEquivalent: "q"
        ))
        statusItem?.menu = menu
        updateStatusItemAppearance()
    }

    /// 用户点开菜单栏图标的那一刻，静默同步一次绑定状态——这是弥补"绑定/解绑在
    /// 服务端完成、客户端需等下一轮 60s 配置轮询才感知"的滞后的主要机制。节流到
    /// 5 秒，避免频繁点开时的网络风暴；不加"正在检查"占位项，本地同步在一秒内
    /// 完成，状态变化后就地重建菜单即可。
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        syncBindingStateIfStale()
        // 不必等 syncBindingStateIfStale 的 5 秒网络节流：剩余时间是纯本地计算，
        // 每次打开菜单都能免费刷新成当下最新的数字。
        refreshTimeSessionMenuItemText()
        startOpenMenuTicking()
    }

    /// 菜单收起：停掉展开期间的每秒刷新，并把期间被推迟的重建补上。
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        openMenuTickTimer?.invalidate()
        openMenuTickTimer = nil
        if menuRebuildPending {
            rebuildMenu()
        }
    }

    /// 菜单展开期间，每秒把剩余时间刷成当下的数字。
    ///
    /// 不复用 timeSessionTimer 是因为职责不同：那颗计时器只在"有进行中的约定"时存活，
    /// 而且它同时还在跑里程碑判定；这里要的仅仅是"菜单开着的这几秒内数字别停"。单独
    /// 一颗生命周期严格等于菜单展开期的计时器，比给那颗塞进一个额外职责更容易讲清楚。
    /// 显式登记 .eventTracking：菜单 tracking 期间运行循环跑在该模式下，只挂 .default
    /// 的计时器在菜单展开的整段时间里一次都不会触发。
    private func startOpenMenuTicking() {
        openMenuTickTimer?.invalidate()
        guard timeSessionMenuItem != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTimeSessionMenuItemText() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        openMenuTickTimer = timer
    }

    /// "关于"窗口：把版本、当前配置摘要、心跳、截图倒计时等只读信息，以及守护说明/
    /// 检查更新等次要操作集中在一处，而不是平铺成一堆一级菜单项（"看看它都记了什么"
    /// 那个导出记录按钮嵌在"守护说明"弹窗里，不在这里单独占一个按钮，避免两处重复入口）。
    ///
    /// 改用普通 NSWindow 而不是 NSAlert：NSAlert 的图标+标题是钉死在左上角的固定布局
    /// 区块，就算把 icon 换成透明占位图、messageText 清空，那块区域仍然会保留原本的
    /// 高度，在 LOGO 上方留出一截无法消除的空白（无公开 API 能改这个内部布局）。换成
    /// 自己的窗口后，LOGO/标题/信息行/按钮全部在同一个 NSStackView 里从上到下排列，
    /// 没有任何隐藏的保留区域，居中和间距完全由 createAboutContentView 决定。
    @objc private func showAboutWindow() {
        aboutWindow?.close()

        var actions: [(title: String, handler: () -> Void, prominent: Bool)] = []
        // 家长已远程开启截图，但本机系统的屏幕录制权限还没给——配置了但实际不生效，
        // 跟菜单栏图标的 ⚠️ 提示是同一个判断条件。
        //
        // 这里是**一次只给一个动作**的两步向导，不是两颗并排的按钮。
        //
        // 之前的做法是把"前往设置授权"和"已授权？重启客户端"两颗按钮平级摆出来，理由是
        // 我们查不出家长到底走到哪一步了（权限有进程级缓存，见 awaitingScreenRecordingGrant），
        // 与其猜错不如都摆出来让家长自己选。但实测下来这是个糟糕的取舍：
        //   · 两颗按钮看不出有先后顺序，家长不知道该先点哪个；
        //   · 点第一颗之后窗口直接关掉，第二步的入口凭空消失；
        //   · 家长在系统设置里授权完回来，没有任何东西提醒他还剩一步，
        //     于是菜单栏一直挂着警示图标，家长的结论是"我明明授权了，这软件坏了"。
        //
        // 现在改成：我们确实查不到权限，但我们**查得到家长有没有点过第一颗按钮**，用这个
        // 已知信息把流程切成两个互斥的状态，每个状态只呈现那一步该做的唯一动作。猜错的
        // 代价也被兜住了——第二步的说明里写清了"如果还没开，就走下面那条回去设置"。
        if client.config.bound && client.config.screenshotEnabled && !checkScreenRecordingPermission() {
            if awaitingScreenRecordingGrant {
                // 第 2 步：家长刚从系统设置回来。重启是此刻唯一该做的事，给蓝底主按钮。
                actions.append((
                    Localization.string(zh: "✅ 我已授权，立即重启生效", en: "✅ I've Granted It — Restart Now"),
                    promptRestartForScreenRecording,
                    true
                ))
                // 兜底：万一家长其实没在设置里打开开关（找错地方 / 找不到 BigDaddy 那一项），
                // 给一条低调的回头路，而不是让他卡在一个只能重启的死胡同里。
                actions.append((
                    Localization.string(zh: "还没授权？再去一次设置", en: "Not Yet? Open Settings Again"),
                    openScreenRecordingSettings,
                    false
                ))
            } else {
                // 第 1 步：还没去过设置。此刻唯一该做的事就是去开开关。
                actions.append((
                    Localization.string(zh: "⚠️ 前往系统设置授权", en: "⚠️ Open System Settings"),
                    openScreenRecordingSettings,
                    true
                ))
            }
        }
        // 网站访问限制没生效：与菜单里那条同一个判据。这个窗口是本 App 事实上的权限
        // 中心（屏幕录制、辅助功能、浏览器自动化都在这儿有修复按钮），此前唯独网络
        // 扩展没有——它的唯一入口是菜单里一条只在"待批准"期间出现的瞬态菜单项，
        // 状态一变成"失败"或"被人关掉"，家长就再也找不到任何可点的东西。
        if let webFilterTitle = webFilterMenuTitle(for: webFilterAttention) {
            actions.append((webFilterTitle, openWebFilterAuthorization, false))
        }
        // 辅助功能缺失：与菜单里那条同一个判据（见 rebuildMenu 里的注释）。放在最前面，
        // 因为它比下面两条影响更大——没有它，连窗口标题这种最基本的记录都是空的。
        if client.config.bound && !AXIsProcessTrustedWithOptions(nil) {
            actions.append((
                Localization.string(zh: "⚠️ 开启辅助功能权限", en: "⚠️ Turn On Accessibility"),
                promptAccessibilityPermission,
                false
            ))
        }
        // 浏览器自动化权限缺失：家长端会看到"有标题、没链接"的日志。这条和屏幕录制那条
        // 的可见性条件不同——它跟 screenshotEnabled 无关，只要设备已绑定、且实际撞到过
        // 被拒的浏览器就该出现（未绑定时没有任何上报，提示也就没有意义）。
        if client.config.bound && !automationDeniedBundleIDs.isEmpty {
            actions.append((
                Localization.string(zh: "⚠️ 允许读取浏览器网址", en: "⚠️ Allow Browser URL Access"),
                promptAutomationPermission,
                false
            ))
            // 并排给出重置入口：上面那颗按钮走的是"重新询问系统"，而系统一旦记下过
            // "不允许"就不会再问，那条路会静默地什么都不发生。这颗是唯一能把状态清回
            // "没问过"的出口，不该只藏在走投无路时才弹出的那个对话框里。
            actions.append((
                Localization.string(zh: "重置浏览器网址授权", en: "Reset Browser URL Access"),
                resetAutomationPermissionsWithConfirmation,
                false
            ))
        }
        // 注：“测试截图”按钮不再放在这里，而是挪到了“下次截屏”信息行的右侧
        // （见 createAboutContentView 的 .nextScreenshot 分支）。
        actions.append((Localization.string(zh: "守护说明", en: "Guardian Info"), showTransparencyInfo, false))
        // 注：导出记录（“看看它都记了什么”）不再单独占一个按钮——“守护说明”弹窗里
        // 已有同样的导出入口，避免重复。
        // 后台静默下载好的更新已就绪：紧挨着"检查更新…"多冒出一个高亮按钮（蓝底白字）。
        // 点击直接调用 Sparkle 交给我们的安装闭包（installPendingUpdate），不走
        // checkForUpdates()——文件已经下载好、安装器也已就绪，再发起一次检查是多余的往返。
        // 用户在弹窗里点过"稍后再说"之后，这里就是他改主意时的入口。
        if let version = pendingUpdateVersion {
            actions.append((
                Localization.string(zh: "安装新版本 \(version) 并重启", en: "Install \(version) & Restart"),
                installPendingUpdate,
                true
            ))
        }
        actions.append((Localization.string(zh: "检查更新…", en: "Check for Updates…"), checkForUpdates, false))
        actions.append((Localization.string(zh: "关闭", en: "Close"), {}, false))
        aboutWindowActions = actions.map { $0.handler }

        let contentView = createAboutContentView(actions: actions)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentView.frame.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "BigDaddy"
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.center()
        window.delegate = self // windowWillClose 里停掉倒计时定时器，见下
        aboutWindow = window

        // 窗口开着时每秒刷新"下次截屏"的倒计时；aboutCountdownField 只有在确实渲染了
        // 该行（截图已开启）时才非空，为空则 tick 里什么都不做。
        startAboutCountdownTimerIfNeeded()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// NSWindowDelegate：关闭"关于"窗口时停掉每秒倒计时定时器并清掉字段引用，避免定时器
    /// 在窗口消失后继续空转、也避免持有已销毁视图的悬垂引用。
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === aboutWindow else { return }
        aboutCountdownTimer?.invalidate()
        aboutCountdownTimer = nil
        aboutCountdownField = nil
        aboutTimeSessionField = nil
    }

    /// 只在"关于"窗口里渲染了"下次截屏"或"时间约定"任一行时才起定时器，两个字段
    /// 各自按是否非空刷新，互不影响。
    private func startAboutCountdownTimerIfNeeded() {
        aboutCountdownTimer?.invalidate()
        aboutCountdownTimer = nil
        guard aboutCountdownField != nil || aboutTimeSessionField != nil else { return }
        aboutCountdownTimer = scheduleCommonModeTimer(interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.aboutCountdownField?.stringValue = self.nextScreenshotRemainingText()
                if let text = self.currentTimeSessionRemainingText() {
                    self.aboutTimeSessionField?.stringValue = text
                }
            }
        }
    }

    /// "下次截屏"剩余时间文案：直接读 screenshotTimer.fireDate，这也是定时截图真正的
    /// 触发时刻——归零的那一刻 screenshotTimer（repeats:true）会触发 performScheduledScreenshot
    /// 并把 fireDate 自动前移一个间隔，所以下一次 tick 会自然显示重新开始的倒计时。
    private func nextScreenshotRemainingText() -> String {
        guard let fireDate = screenshotTimer?.fireDate else {
            return Localization.string(zh: "--:--", en: "--:--")
        }
        let remaining = max(0, Int(fireDate.timeIntervalSinceNow))
        return String(format: Localization.string(zh: "%02d:%02d 后", en: "in %02d:%02d"),
                      remaining / 60, remaining % 60)
    }

    /// "关于"窗口里"测试截图"按钮的响应：不关闭窗口（方便连续测试、观察倒计时），
    /// 直接走手动截图路径（reason: manual，已不受相似度去重影响，见 captureAndSendScreenshot）。
    @objc private func aboutTestScreenshotTapped() {
        sendScreenshotNow()
    }

    /// "关于"窗口按钮的统一响应入口：tag 是按钮在 actions 数组里的下标，关掉窗口后
    /// 再执行对应动作，动作里如果又要弹别的窗口/弹窗，不会跟已关闭的"关于"窗口打架。
    @objc private func aboutActionTapped(_ sender: NSButton) {
        let index = sender.tag
        sender.window?.close()
        if index >= 0 && index < aboutWindowActions.count {
            aboutWindowActions[index]()
        }
    }

    /// "关于"窗口的内容视图：LOGO、标题、只读信息行、按钮全部放进同一个纵向 NSStackView，
    /// 顶部 LOGO/标题靠 alignment = .centerX 在整个宽度内水平居中，信息行/按钮撑满宽度、
    /// label:value 两栏纵向对齐。信息行只在对应信息"当下有意义"时才出现——截图未开启
    /// 就不提截屏间隔，没配置通知渠道就不提通知渠道，而不是展示一个此刻无意义的占位值。
    private func createAboutContentView(actions: [(title: String, handler: () -> Void, prominent: Bool)]) -> NSView {
        let width: CGFloat = Localization.isChinese ? 300 : 340
        let labelWidth: CGFloat = Localization.isChinese ? 76 : 132
        let rowHeight: CGFloat = 20
        let edgePadding: CGFloat = 24

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: edgePadding, left: edgePadding, bottom: edgePadding, right: edgePadding)
        container.translatesAutoresizingMaskIntoConstraints = false

        let logoImage = ShieldIcon.image(pointSize: 46)
        let logo = NSImageView()
        logo.image = logoImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor // 模板图随浅/深色模式自适应
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: logoImage.size.width).isActive = true
        logo.heightAnchor.constraint(equalToConstant: logoImage.size.height).isActive = true

        let titleLabel = NSTextField(labelWithString: "BigDaddy")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 20)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        container.addArrangedSubview(logo)
        container.addArrangedSubview(titleLabel)
        container.setCustomSpacing(18, after: titleLabel)

        aboutCountdownField = nil // 每次重建窗口都重置，只有真的渲染了倒计时行才会被赋值
        aboutTimeSessionField = nil
        for row in aboutInfoRows() {
            switch row {
            case let .text(label, value):
                container.addArrangedSubview(makeInfoRow(label: label, value: value, width: width, labelWidth: labelWidth, rowHeight: rowHeight))
            case let .nextScreenshot(initialValue):
                container.addArrangedSubview(makeNextScreenshotRow(initialValue: initialValue, width: width, labelWidth: labelWidth))
            case let .timeSession(initialValue):
                container.addArrangedSubview(makeTimeSessionRow(initialValue: initialValue, width: width, labelWidth: labelWidth, rowHeight: rowHeight))
            }
        }
        if let lastRow = container.arrangedSubviews.last {
            container.setCustomSpacing(20, after: lastRow)
        }

        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(aboutActionTapped(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            if action.prominent {
                // 蓝底白字：普通按钮手动设 bezelColor 只染背景、标题仍是黑色（浅色模式下
                // 对比度不足），这里显式给白色 attributedTitle 配 systemBlue 底色，且不
                // 随系统强调色变化（controlAccentColor 可能被用户改成浅色导致看不清）。
                button.bezelColor = .systemBlue
                button.attributedTitle = NSAttributedString(
                    string: action.title,
                    attributes: [
                        .foregroundColor: NSColor.white,
                        .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    ]
                )
            }
            container.addArrangedSubview(button)
        }
        // 最后一个按钮固定是"关闭"：Esc 键直接关闭面板，不需要挨个数按钮再点。
        (container.arrangedSubviews.last as? NSButton)?.keyEquivalent = "\u{1b}"

        let fittingHeight = container.fittingSize.height
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: width + edgePadding * 2, height: fittingHeight))
        parentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: parentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: parentView.trailingAnchor)
        ])
        return parentView
    }

    /// "关于"面板的信息行：普通的 label:value，或特殊的"下次截屏"行（带实时倒计时 +
    /// 行内"测试截图"按钮），后者由 createAboutContentView 单独渲染。
    private enum AboutInfoRow {
        case text(label: String, value: String)
        case nextScreenshot(initialValue: String)
        case timeSession(initialValue: String)
    }

    /// "关于"面板只读信息行的数据源：每一行只在对应信息"当下有意义"时才加入。
    private func aboutInfoRows() -> [AboutInfoRow] {
        var rows: [AboutInfoRow] = []
        if client.config.bound {
            rows.append(.text(label: Localization.string(zh: "状态", en: "Status"),
                              value: Localization.string(zh: "已受保护", en: "Protected")))
            // 有进行中的约定时排在"状态"之后：这是家长"现在正在发生"的一件事，
            // 比下面截图/通知渠道这些长期不变的配置摘要更值得靠前看到。
            if let timeSessionText = currentTimeSessionRemainingText() {
                rows.append(.timeSession(initialValue: timeSessionText))
            }
            rows.append(.text(
                label: Localization.string(zh: "截图", en: "Screenshots"),
                value: client.config.screenshotEnabled
                    ? Localization.string(zh: "已开启（家长可远程截屏）", en: "ON (parent can capture)")
                    : Localization.string(zh: "未开启", en: "OFF")
            ))
            rows.append(.text(label: Localization.string(zh: "最近心跳", en: "Last heartbeat"), value: client.lastHeartbeatDescription))
            if client.config.screenshotEnabled {
                // 截图开启时始终渲染"下次截屏"行——它同时承载实时倒计时和"测试截图"按钮；
                // 拿不到 fireDate（理论上不该发生）时退回 --:--，但按钮照常可用。
                rows.append(.nextScreenshot(initialValue: nextScreenshotRemainingText()))
                rows.append(.text(
                    label: Localization.string(zh: "截屏间隔", en: "Interval"),
                    value: Localization.string(zh: "\(client.config.screenshotIntervalMins) 分钟",
                                               en: "\(client.config.screenshotIntervalMins) min")
                ))
            }
            let channels = client.config.notificationChannels
            var channelNames: [String] = []
            // emailEnabled/telegramEnabled 缺省（nil）按已启用处理，只有家长显式关闭
            // 开关（false）时才不算——语义与后端 processScreenshotUpload 的转发门禁一致，
            // 避免"地址还在、开关已关"时这里仍然显示成"正在转发"。
            if !(channels.email ?? "").isEmpty && channels.emailEnabled != false {
                channelNames.append(Localization.string(zh: "邮件", en: "Email"))
            }
            if !(channels.telegramChatId ?? "").isEmpty && channels.telegramEnabled != false {
                channelNames.append("Telegram")
            }
            if !(channels.whatsappPhone ?? "").isEmpty { channelNames.append("WhatsApp") }
            if !channelNames.isEmpty {
                rows.append(.text(
                    label: Localization.string(zh: "通知渠道", en: "Notify via"),
                    value: channelNames.joined(separator: Localization.string(zh: "、", en: ", "))
                ))
            }
        } else {
            rows.append(.text(label: Localization.string(zh: "状态", en: "Status"),
                              value: Localization.string(zh: "尚未绑定家长账号", en: "Unbound")))
        }
        rows.append(.text(label: Localization.string(zh: "版本", en: "Version"), value: AppVersion.current))
        return rows
    }

    /// 单条 label:value 信息行：label 固定宽度右对齐、value 左对齐，靠固定 label 宽度
    /// 让多行的冒号/数值纵向对齐成两栏。
    private func makeInfoRow(label: String, value: String, width: CGFloat, labelWidth: CGFloat, rowHeight: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 12)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let valueField = NSTextField(labelWithString: value)
        valueField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        valueField.textColor = .labelColor
        valueField.alignment = .left
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(valueField)
        return row
    }

    /// "下次截屏"行：与普通信息行同样是 label 右对齐 + value 左对齐，但 value 会被
    /// aboutCountdownTimer 每秒刷新成实时倒计时，并在最右侧多一个小号"测试截图"按钮
    /// （点击不关闭窗口，方便连续测试和观察倒计时）。行高比普通行大一点以容纳按钮。
    private func makeNextScreenshotRow(initialValue: String, width: CGFloat, labelWidth: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let labelField = NSTextField(labelWithString: Localization.string(zh: "下次截屏", en: "Next screenshot"))
        labelField.font = NSFont.systemFont(ofSize: 12)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let valueField = NSTextField(labelWithString: initialValue)
        valueField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        valueField.textColor = .labelColor
        valueField.alignment = .left
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        aboutCountdownField = valueField // 交给 aboutCountdownTimer 每秒刷新

        let testButton = NSButton(
            title: Localization.string(zh: "测试截图", en: "Test"),
            target: self, action: #selector(aboutTestScreenshotTapped)
        )
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.font = NSFont.systemFont(ofSize: 11)
        testButton.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(valueField)
        row.addArrangedSubview(testButton)
        return row
    }

    /// "时间约定"信息行：与普通 label:value 行（makeInfoRow）结构一致，只是把 value
    /// 字段交给 aboutCountdownTimer 每秒刷新，不需要行内按钮。
    private func makeTimeSessionRow(initialValue: String, width: CGFloat, labelWidth: CGFloat, rowHeight: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let labelField = NSTextField(labelWithString: Localization.string(zh: "时间约定", en: "Time left"))
        labelField.font = NSFont.systemFont(ofSize: 12)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let valueField = NSTextField(labelWithString: initialValue)
        valueField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        valueField.textColor = .labelColor
        valueField.alignment = .left
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        aboutTimeSessionField = valueField // 交给 aboutCountdownTimer 每秒刷新

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(valueField)
        return row
    }

    /// 未绑定态的合并入口：先问清楚"哪种方式"，再分派到对应的原有弹窗，
    /// 避免两条并列菜单项都叫"绑定"、孩子分不清该点哪个。
    @objc private func showBindEntry() {
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "绑定本设备", en: "Bind This Mac")
        alert.informativeText = Localization.string(
            zh: "选择一种方式完成绑定：",
            en: "Choose how you'd like to bind:"
        )
        applyShieldIcon(to: alert)
        alert.addButton(withTitle: Localization.string(
            zh: "在本机显示绑定码，让家长输入", en: "Show a code here for my parent to enter"
        ))
        alert.addButton(withTitle: Localization.string(
            zh: "输入家长已经给我的绑定码", en: "Enter a code my parent already gave me"
        ))
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn: showDeviceBindCode()
        case .alertSecondButtonReturn: showBindCodeInput()
        default: break
        }
    }

    private func syncBindingStateIfStale() {
        guard Date().timeIntervalSince(lastBindingSyncAt) > 5 else { return }
        lastBindingSyncAt = Date()
        // pollConfigForChildVisibility 已包含凭据失效兜底、解绑通知、bound 翻转后重排定时器，
        // 复用它即可，菜单会在其内部的 rebuildMenu 中就地更新。
        Task { [weak self] in await self?.pollConfigForChildVisibility() }
    }

    /// 展示绑定码/二维码后启动的一段高频探测：绑定在服务端完成（家长在仪表盘或本机输码），
    /// 用它把"绑定成功"的反馈从最长 60s 压到约 3s。轮询用普通 async（弹窗已关闭，运行循环
    /// 正常），检测到 bound=true 立即刷新配置、重建菜单并弹成功提示；最多探测 2 分钟。
    private func startBindDetectionBurst() {
        guard !client.config.bound else { return }
        bindDetectionTask?.cancel()
        bindDetectionTask = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.client.credentialsInvalid {
                    await self.client.register()
                }
                let changed = self.client.credentialsInvalid
                    ? false
                    : await self.client.refreshConfig().changed
                if self.client.config.bound {
                    // 绑定成功：立即发送一次心跳，让后端即时感知设备上线
                    await self.client.sendHeartbeat(event: .start)
                    await MainActor.run {
                        // 绑定即家长接管：强制恢复开机自启，抵消未绑定期间可能的关闭
                        self.enforceLaunchAtLoginOnBind()
                        self.scheduleTimers()
                        self.rebuildMenu()
                        self.updateStatusItemAppearance()
                        // 绑定即家长在场：此刻是把浏览器授权一次问清楚的最好时机，
                        // 错过它就只能等孩子日后被逐个浏览器零散打断（见该方法注释）
                        self.warmAutomationConsentIfNeeded()
                        self.postLocalNotice(
                            title: Localization.string(zh: "绑定成功", en: "Binding successful"),
                            body: Localization.string(
                                zh: "本设备已与家长账户建立守护关系。",
                                en: "This Mac is now linked to the parent account."
                            )
                        )
                    }
                    return
                }
                if changed {
                    await MainActor.run { self.rebuildMenu() }
                }
            }
        }
    }

    /// 让菜单栏图标反映当前"截图是否开启 / 是否正在截图 / 权限是否缺失"，作为孩子端常驻可见指示。
    ///
    /// 四种状态**共用同一个满尺寸的品牌盾牌**，状态由盾牌右下角一枚实心圆徽章承担
    /// （见 ShieldIcon.Variant）：没有徽章=守护中未截图，实心圆点=截图已开启，
    /// 同心圆（多一圈，读作快门张开）=此刻正在截图，裸感叹号（无三角外框）=缺权限。徽章走"挖洞→填实心→镂空
    /// 刻图案"三段式，不是简单地把两个图形直接叠在一起——为什么，见 ShieldIcon
    /// 里那段记录（早期版本让盾牌和符号两个"都带镂空"的图形直接做透明度叠加，
    /// 效果随机且像随手拼贴，而不是设计过的图标）。
    ///
    /// 浏览器网址未授权也走同一个 warning 符号：两者是同一类问题（配置了但实际不生效），
    /// 用同一套视觉语言，点开菜单第一眼就能看到对应那条待办。屏幕录制排在前面——
    /// 它缺失时家长一张截图都收不到，比"有标题没链接"更严重。
    private func updateStatusItemAppearance(capturing: Bool = false) {
        guard let button = statusItem?.button else { return }
        // 不能只看 screenshotEnabled：解绑时 refreshConfig() 只翻转 bound，刻意保留
        // screenshotEnabled 原值不动（见该函数注释——不能用"未绑定"信号覆盖整份本地
        // 配置）。结果是"曾经绑定且开过截图的设备被解绑后"，screenshotEnabled 仍是
        // true，图标会一直挂着"正在看着"的圆环角标，跟菜单里"尚未绑定"的文字自相矛盾。
        let on = client.config.bound && client.config.screenshotEnabled
        let missingScreenRecording = on && !checkScreenRecordingPermission()
        let missingAutomation = client.config.bound && !automationDeniedBundleIDs.isEmpty
        // 待批准、被人关掉、启用失败三种都要变警示态：它们都是"家长配置了、实际却不
        // 生效"，跟屏幕录制缺权限是同一类问题。此前只有第一种会让图标变色，另外两种
        // 图标一切如常，家长没有任何理由去点开菜单。
        let webFilterAttention = self.webFilterAttention
        // 辅助功能缺失也要让图标变成警示态：菜单里那条「⚠️ 辅助功能未授权 · 点此修复」
        // 是唯一的修复入口，而没有人会去点一个看起来一切正常的图标。少了这一条，那个
        // 入口等于藏在一扇没有门把手的门后面。
        let missingAccessibility = client.config.bound && !AXIsProcessTrustedWithOptions(nil)
        let missingPermission = missingScreenRecording || missingAutomation || missingAccessibility
            || webFilterAttention != .none

        let variant: ShieldIcon.Variant
        let baseDesc: String
        if capturing {
            variant = .capturing
            baseDesc = Localization.string(zh: "BigDaddy 正在截图", en: "BigDaddy capturing screenshot")
        } else if missingPermission {
            variant = .warning
            // 优先说最严重的那一条：缺辅助功能连窗口标题都记不到，比"有标题没链接"更致命。
            if missingAccessibility {
                baseDesc = Localization.string(zh: "BigDaddy 缺少辅助功能权限",
                                           en: "BigDaddy is missing Accessibility access")
            } else if webFilterAttention == .disabledExternally {
                // 排在"待批准"前面：待批准是"还没开始生效"，被人关掉是"本来在拦、
                // 现在不拦了"，后者对家长是一次实实在在的失守。
                baseDesc = Localization.string(zh: "BigDaddy 的网站访问限制已被关闭",
                                           en: "BigDaddy website restrictions were turned off")
            } else if case .failed = webFilterAttention {
                baseDesc = Localization.string(zh: "BigDaddy 的网站访问限制启用失败",
                                           en: "BigDaddy website restrictions failed to start")
            } else if webFilterAttention != .none {
                baseDesc = Localization.string(zh: "BigDaddy 等待授权网站访问限制",
                                           en: "BigDaddy is waiting for website restriction approval")
            } else if missingScreenRecording {
                baseDesc = Localization.string(zh: "BigDaddy 截图已开启但缺少系统权限",
                                           en: "BigDaddy screenshots on but missing system permission")
            } else {
                baseDesc = Localization.string(zh: "BigDaddy 缺少浏览器网址读取权限",
                                           en: "BigDaddy is missing browser URL access")
            }
        } else if on {
            variant = .watching
            baseDesc = Localization.string(zh: "BigDaddy 截图已开启", en: "BigDaddy screenshots on")
        } else {
            variant = .brand
            baseDesc = Localization.string(zh: "BigDaddy 守护中，未开启截图",
                                       en: "BigDaddy on guard, screenshots off")
        }

        // 右上角"受限"徽章：独立于上面右下角那枚，两者可以同时显示（比如同时缺权限
        // 又在限网）。webFilterAttention == .none 这道守卫是正确性要求，不是可选项——
        // isRestrictingWebAccess 只反映"策略要求启用"，扩展被人从系统设置里关掉时
        // （webFilterAttention == .disabledExternally）它依然会是 true；那种情况下
        // 一条都没拦，显示"受限"会是一句谎言，此时应该只靠上面已经在显示的警示徽章
        // 说清楚"防线失守了"，不能再让右上角同时说"正在限制"自相矛盾。
        let isRestricted = webFilterController.isRestrictingWebAccess && webFilterAttention == .none
        let desc: String
        if isRestricted {
            let restrictedDesc = Localization.string(zh: "网站访问受限", en: "website access restricted")
            desc = baseDesc + " · " + restrictedDesc
        } else {
            desc = baseDesc
        }

        let image = ShieldIcon.image(pointSize: 16, variant: variant, restricted: isRestricted)
        image.accessibilityDescription = desc
        button.image = image
        button.title = ""
    }

    /// 启动一次即常驻运行，不随 screenshotEnabled 开关本身启停——判断"要不要关心权限"
    /// 这件事放在 tick 内部（截图关闭时直接跳过，见 refreshIconIfPermissionChanged），
    /// 定时器本身不用在每次开关翻转时重新启停，逻辑更简单，也不会有"刚好错过开关那一刻
    /// 没跟着启停"的边界情况。
    private func schedulePermissionPollTimer() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = scheduleCommonModeTimer(interval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshIconIfPermissionChanged()
            }
        }
    }

    /// 屏幕录制权限只在截图开启时才有意义（关闭时图标固定是盾牌，跟权限无关），所以
    /// 截图关闭时直接跳过查询——CGPreflightScreenCaptureAccess() 是一次到 tccd 的本地
    /// IPC，虽然开销很小，但没必要每 2 秒都问一次用不上的问题。只在结果真的变化时才
    /// 重绘图标，避免每次 tick 都无谓刷新。
    ///
    /// 注意：这里只处理"权限被授予/撤回"这一种变化——"家长在后台关闭了截图"这件事
    /// 走的是另一条已有路径（远端配置轮询 pollConfigForChildVisibility，最长 60 秒
    /// 或者绑定/心跳等事件触发时更快），本身就会调用 updateStatusItemAppearance()
    /// 落回盾牌图标，不需要在这里重复处理。
    private func refreshIconIfPermissionChanged() {
        guard client.config.screenshotEnabled else {
            lastKnownScreenRecordingPermission = nil
            return
        }
        let current = checkScreenRecordingPermission()
        guard current != lastKnownScreenRecordingPermission else { return }
        lastKnownScreenRecordingPermission = current
        updateStatusItemAppearance()
    }

    /// 每次实际发生截图时被调用：图标短暂切到"相机"态，并推送本机通知，确保孩子端即时可见。
    @objc private func onScreenshotSent() {
        updateStatusItemAppearance(capturing: true)
        screenshotFlashTimer?.invalidate()
        screenshotFlashTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusItemAppearance() }
        }
        postLocalNotice(
            title: Localization.string(zh: "已向家长发送一张截图", en: "A screenshot was sent to your parent"),
            body: Localization.string(zh: "本次截图已写入“本机守护记录”，可在菜单中导出查看。",
                                      en: "This capture is written to the local Guardian Log; export it from the menu.")
        )
    }

    /// 定时/命令截图因缺屏幕录制权限静默失败时被调用。节流成"同一段缺权限期间只提醒
    /// 一次"（见 missingPermissionNoticeShown），避免定时器每隔几分钟就因为同一个没解决
    /// 的问题反复弹通知骚扰用户；这段"期间"由截图开关的每一次翻转重新界定（见
    /// pollConfigForChildVisibility 里 after != before 分支对这个 flag 的复位）。
    @objc private func onScreenshotMissingPermission() {
        guard !missingPermissionNoticeShown else { return }
        missingPermissionNoticeShown = true
        postLocalNotice(
            title: Localization.string(zh: "截图仍未生效", en: "Screenshots still not working"),
            body: Localization.string(
                zh: "本机还没有屏幕录制权限。如果你已经在系统设置里开启了，请打开菜单栏「关于 BigDaddy…」，点击「已授权？重启客户端」使其生效。",
                en: "This Mac hasn't granted Screen Recording permission yet. If you've already enabled it in System Settings, open “About BigDaddy…” from the menu bar and tap “Granted? Restart App” to apply it."
            )
        )
    }

    /// 前台浏览器因自动化权限拿不到 URL 时被调用（由 activeWindowInfo 广播）。
    ///
    /// 分两种状态给完全不同的处理，这是 macOS 自动化权限的硬约束：
    /// - notDetermined：系统还没问过用户，这时**主动发一次 Apple Event 才能触发**系统
    ///   原生授权框。这也是唯一能让 BigDaddy 出现在「系统设置 → 隐私与安全性 → 自动化」
    ///   列表里的方式——没被弹过窗的 App 在那个列表里根本不存在，直接叫用户去设置里
    ///   打开是找不到开关的。
    /// - denied：用户点过"不允许"，系统此后永远不再弹窗，只能引导去系统设置手动勾选。
    ///
    /// 每个浏览器按 automationNoticeInterval 节流，孩子在浏览器里每分钟心跳一次，
    /// 不节流就是每分钟一个弹窗/通知。
    @objc private func onBrowserAutomationBlocked(_ note: Notification) {
        guard let bundleID = note.userInfo?["bundleID"] as? String else { return }
        let reason = note.userInfo?["reason"] as? String
        // activeWindowInfo 跑在 Task.detached 的后台线程上（见 sendHeartbeat 的注释），
        // NotificationCenter 又是在发送方线程同步派发的——这个处理器因此默认就在后台
        // 线程上执行，而它下面碰的全是 UI（菜单重建、本机通知、NSAlert）。显式回主线程。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.onBrowserAutomationBlocked(note) }
            return
        }
        if reason == BigDaddyClient.UrlUnavailableReason.notPermitted.rawValue {
            automationDeniedBundleIDs.insert(bundleID)
            // 菜单栏那条一级警示项和图标状态都由这个集合驱动，插入后要立刻重绘——
            // 常驻入口不受下面的通知节流管辖，本来就该在第一时间出现。
            rebuildMenu()
        }
        guard shouldPostAutomationNotice(for: bundleID) else { return }

        let browserName = Self.browserDisplayName(forBundleID: bundleID)
        if reason == BigDaddyClient.UrlUnavailableReason.notDetermined.rawValue {
            // 同样用真实 Apple Event 触发系统询问，理由见 probeAutomation。
            // 这个调用会同步阻塞到用户点选为止，必须离开主线程，否则整个客户端
            // （含菜单栏图标）在用户做决定之前都是僵住的。
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let probe = self?.client.probeAutomation(bundleID: bundleID)
                // 内层闭包显式重新弱捕获 self，而不是沿用外层 [weak self] 解出来的那个
                // 变量——后者是"跨并发边界引用被捕获的 var"，Swift 6 下是错误。
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if probe?.permission == .granted {
                        self.automationDeniedBundleIDs.remove(bundleID)
                        // 授权当场生效，下一次心跳就能带上 URL，无需重启（这点和屏幕录制不同）
                        self.rebuildMenu()
                        return
                    }
                    self.automationDeniedBundleIDs.insert(bundleID)
                    self.noticeAutomationDenied(browserName: browserName)
                }
            }
            return
        }
        noticeAutomationDenied(browserName: browserName)
    }

    /// 已经主动预热过自动化授权的浏览器 bundle id，跨启动持久化
    private static let warmedAutomationTargetsKey = "BigDaddyWarmedAutomationTargets"

    /// 绑定完成后，主动给每个"已安装且正在运行"的受支持浏览器各发一次真实 Apple Event，
    /// 让 macOS 当场弹出授权询问、并在 TCC 里建出记录。
    ///
    /// 为什么非要主动发：系统设置的「隐私与安全性 → 自动化」**只列出已经产生过 TCC 记录
    /// 的 App**，而记录只有在真的发过一次事件之后才存在。不预热的话，家长按我们的提示
    /// 打开那个面板，看到的是一个根本没有 BigDaddy 的列表——"去设置里勾上"这条退路在
    /// 那之前是死的（showAutomationPromptUnavailable 就是在给这种情况擦屁股）。
    ///
    /// 三条约束都是必要的，不是保守：
    /// - **只在绑定后**：未绑定时不上报任何数据，这个权限没有意义，不该打扰；
    /// - **只对运行中的浏览器**：`tell application id` 会把没运行的目标 App **启动起来**，
    ///   绑定那一刻凭空弹出四个浏览器窗口是不可接受的；
    /// - **每个浏览器一生只预热一次**（持久化）：预热的目的是建记录，记录建好之后再发
    ///   就只是重复打扰了；后续状态变化由运行期的 onBrowserAutomationBlocked 接手。
    ///
    /// 串行而不是并发：并发发四个事件会让系统把四个授权框叠在一起，用户看不清自己在同意什么。
    private func warmAutomationConsentIfNeeded() {
        guard client.config.bound else { return }
        let warmedKey = Self.warmedAutomationTargetsKey
        let warmed = Set(UserDefaults.standard.stringArray(forKey: warmedKey) ?? [])
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let urlTargets = BigDaddyClient.installedSupportedBrowsers()
            .filter { running.contains($0) && !warmed.contains($0) }
        // Firefox 系也要问一次授权：它给不出网址，但**窗口标题**恰恰要靠同一套自动化
        // 权限才读得到（见 BigDaddyClient.installedTitleOnlyBrowsers）。不在家长在场时
        // 问掉，孩子第一次打开 Firefox 时家长端就会先收到一条既没标题也没链接的空记录。
        let titleTargets = BigDaddyClient.installedTitleOnlyBrowsers()
            .filter { running.contains($0) && !warmed.contains($0) }
        guard !urlTargets.isEmpty || !titleTargets.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 每次调用都会同步阻塞到用户在系统授权框上点选为止——这正是我们要的效果，
            // 但因此绝不能放在主线程上，否则菜单栏图标在用户做决定之前整个僵住。
            var stillBlocked: [String] = []
            for bundleID in urlTargets {
                guard let probe = self?.client.probeAutomation(bundleID: bundleID) else { return }
                switch probe.permission {
                case .granted, .targetNotRunning:
                    continue
                default:
                    stillBlocked.append(bundleID)
                }
            }
            // 标题型浏览器只负责把授权框问出来，**不参与** stillBlocked 的判定：
            // automationDeniedBundleIDs 驱动的是「浏览器网址未授权」那条待办，而
            // Firefox 无论授权与否都给不出网址，混进去就是给家长派一件做不完的活。
            for bundleID in titleTargets {
                self?.client.warmTitleAutomation(bundleID: bundleID)
            }
            // 记账放在探测之后：中途进程被杀的话，这些浏览器下次启动还会再预热一次，
            // 比"记了账却没真发出去、从此再也不预热"要好。
            UserDefaults.standard.set(Array(warmed.union(urlTargets).union(titleTargets)), forKey: warmedKey)
            // 跨线程边界前定格成不可变副本：直接捕获上面那个 var，编译器无法证明
            // "派发之后不会再被改"，Swift 6 下会直接判成错误（旧版编译器只给警告）。
            let blocked = stillBlocked
            DispatchQueue.main.async { [weak self] in
                guard let self, !blocked.isEmpty else { return }
                self.automationDeniedBundleIDs.formUnion(blocked)
                self.rebuildMenu()
            }
        }
    }

    /// 距离上次就这个浏览器提醒是否已经超过 automationNoticeInterval。
    /// 返回 true 的同时就地记账，调用方拿到 true 即可直接提醒。
    private func shouldPostAutomationNotice(for bundleID: String) -> Bool {
        if let last = automationNoticeShownAt[bundleID],
           Date().timeIntervalSince(last) < Self.automationNoticeInterval {
            return false
        }
        automationNoticeShownAt[bundleID] = Date()
        return true
    }

    private func noticeAutomationDenied(browserName: String) {
        rebuildMenu()
        postLocalNotice(
            title: Localization.string(zh: "网址记录未生效", en: "Website logging not working"),
            body: Localization.string(
                zh: "BigDaddy 还不能读取 \(browserName) 的当前网址，家长端只会看到页面标题、看不到链接。请点开菜单栏的 BigDaddy 图标，选择「⚠️ 浏览器网址未授权 · 点此修复」。",
                en: "BigDaddy can't read the current address in \(browserName), so the parent dashboard shows page titles without links. Click the BigDaddy menu bar icon and choose “⚠️ Browser URL access off · Fix it”."
            )
        )
    }

    /// bundle id → 给用户看的浏览器名。优先问系统要本地化名称（用户装的是中文版就显示
    /// 中文名），拿不到时退回 bundle id 末段，至少比整串 id 可读。
    private static func browserDisplayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// 本机通知（无需额外权限），用于把"发生了什么"即时告知使用本机的孩子。
    private func postLocalNotice(title: String, body: String) {
        let notice = NSUserNotification()
        notice.title = title
        notice.informativeText = body
        NSUserNotificationCenter.default.deliver(notice)
    }

    // 跟踪 IDLE/RESUME 状态转换
    private var wasIdle = false

    /// 电源与登录会话事件的监听。
    ///
    /// 没有这四个事件时，"孩子合上了 MacBook""孩子锁屏去吃饭了""家里断网了""客户端被强杀"
    /// 在家长端全部收敛成同一个 OFFLINE——而这几种情况家长该做的事完全不同。
    ///
    /// 两套通知中心不能混：睡眠/唤醒走 NSWorkspace 的通知中心，锁屏/解锁只在
    /// **DistributedNotificationCenter** 上以 `com.apple.screenIsLocked` /
    /// `com.apple.screenIsUnlocked` 广播（没有对应的 NSWorkspace 常量）。
    private func installPowerAndSessionObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        // willSleep 的处理块是**同步**执行的，系统会等它返回（只给几秒）才真正睡下去。
        // 这正是唯一能在睡眠前把 SLEEP 发出去的窗口，所以这里刻意用同步发送——
        // 编译器会警告"不能从 Sendable 闭包引用 MainActor 隔离的 client 属性"（queue: nil
        // 意味着这个闭包可能在任意线程同步执行，不保证是主线程），但这里**不能**用
        // `Task { @MainActor in ... }` 包一层去满足它：那样这次调用会变成排到下一轮主
        // 循环才执行的异步任务，闭包本身立即返回、系统立刻继续休眠流程，等于完全废掉
        // "同步阻塞、确保这条心跳已经发出"这个设计的全部意义。`client` 是一个不涉及
        // AppDelegate 自身状态、专为跨线程调用设计的普通类实例，这里保留警告、不做处理。
        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            AuditLog.record("SYSTEM_WILL_SLEEP")
            self.client.sendEventSync(event: .sleep, timeout: 2.0)
        }

        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main 保证这个闭包本来就跑在主线程上，但闭包类型本身仍是非隔离的
            // Sendable 闭包，编译器看不出"主线程"和"MainActor"这里其实是同一回事——
            // 包一层 Task { @MainActor in } 是本文件里 scheduleNextHeartbeat 等处已经在用
            // 的标准写法，让编译器认可这次调用合法，运行时行为不变（下一轮主循环立即执行）。
            Task { @MainActor [weak self] in
                self?.handleResumeFromSystemEvent(event: .wake, auditLine: "SYSTEM_DID_WAKE")
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            AuditLog.record("SCREEN_LOCKED")
            Task { await self.client.sendHeartbeat(event: .screenLock) }
        }

        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleResumeFromSystemEvent(event: .screenUnlock, auditLine: "SCREEN_UNLOCKED")
            }
        }
    }

    /// 唤醒 / 解锁的共同处理：这两件事都意味着有人回到了机器前。
    ///
    /// 四件事必须一起做，少任何一件都会留下"家长端显示空闲、孩子其实已经在用"的窗口，
    /// 或时间约定倒计时算错：
    /// 1. 重置空闲计时起点——否则 `isIdle` 会把睡眠期间累积的无输入时长算成空闲；
    /// 2. 把 wasIdle 归位并按活跃节奏重排心跳——否则下一次心跳还排在 15 分钟之后；
    /// 3. 顺手推一次补发——睡眠期间积压的队列正等着一个触发点，而网络路径可能并未翻转
    ///    （唤醒后 Wi-Fi 自动重连通常会翻转，但有线网络/一直可达的情况不会）；
    /// 4. 重新拉一次配置并重新校准时间约定的本地截止点——`ProcessInfo.systemUptime`
    ///    的定义是"系统保持唤醒的时长"，不计入睡眠时长。若不在这里重新定锚，孩子合盖
    ///    10 分钟对本地倒计时零消耗，与"墙钟到点"的设计矛盾（家长设定的是真实时间，
    ///    不是"孩子清醒使用电脑的时间"）。screenUnlock 场景机器全程醒着，这一步是
    ///    无害的冗余刷新，不必单独判断 event 类型来跳过。
    private func handleResumeFromSystemEvent(event: EventType, auditLine: String) {
        handleResume(event: event, auditLine: auditLine, resetActivityFloor: true)
    }

    private func stopIdleActivityMonitor() {
        idleActivityTimer?.invalidate()
        idleActivityTimer = nil
    }

    private func scheduleIdleActivityMonitor() {
        stopIdleActivityMonitor()
        guard wasIdle else { return }
        idleActivityTimer = scheduleCommonModeTimer(
            interval: idleActivityPollInterval,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.wasIdle else {
                    self.stopIdleActivityMonitor()
                    return
                }
                guard !self.client.isIdle else { return }
                self.handleResume(event: .resume)
            }
        }
    }

    private func handleResume(
        event: EventType,
        auditLine: String? = nil,
        resetActivityFloor: Bool = false
    ) {
        if let auditLine { AuditLog.record(auditLine) }
        if resetActivityFloor { client.noteActivityFloor() }
        wasIdle = false
        stopIdleActivityMonitor()
        scheduleNextHeartbeat()
        scheduleNextCommandPoll()
        Task {
            await client.sendHeartbeat(event: event)
            await client.startBackfillIfNeeded()
            let intervalBeforeResume = client.config.screenshotIntervalMins
            _ = await client.refreshConfig()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.client.config.screenshotIntervalMins != intervalBeforeResume {
                    self.scheduleScreenshotTimer()
                }
                self.syncTimeSessionState()
                self.triggerImmediateCommandPollIfNeeded()
            }
        }
    }

    /// `Timer.scheduledTimer(withTimeInterval:repeats:block:)` 只把计时器加入当前
    /// RunLoop 的 `.default` 模式。任何 NSAlert.runModal() 打开期间，RunLoop 会切到
    /// `.modalPanel` 模式，`.default` 模式的计时器完全不会触发——心跳/命令轮询/配置
    /// 刷新/定时截图会在弹窗开着的这段时间里全部静默暂停，弹窗一关才恢复，表现为
    /// 家长端看到的心跳"断断续续"。改用手动创建 Timer 并加入 `.common` 模式（涵盖
    /// default 与 modalPanel），弹窗打开时这些后台任务也能正常触发。
    /// 注：计时器体里的 Task { @MainActor } 在"从主 actor 任务里调起的弹窗"（目前
    /// 只有未绑定态的绑定码弹窗）期间会延后到弹窗关闭才执行；安全退出/关于等直接
    /// 从菜单动作调起的弹窗期间照常执行（实测结论见 showDeviceBindCode 注释）——
    /// 已绑定设备会出现的弹窗都属于后者，心跳在这些弹窗打开期间不会中断。
    private func scheduleCommonModeTimer(interval: TimeInterval, repeats: Bool, block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// 只重排"定时截图"这一个计时器：家长在仪表盘改了截图间隔后，运行期配置轮询
    /// （pollConfigForChildVisibility）需要单独把它按新间隔重排，而不必连带把心跳/命令
    /// 轮询的自重排一次性打断——那些跟截图间隔无关。
    private func scheduleScreenshotTimer() {
        screenshotTimer?.invalidate()
        // 定时截图（由后端 screenshotEnabled 控制，调度本身照常）
        screenshotTimer = scheduleCommonModeTimer(
            interval: TimeInterval(client.config.screenshotIntervalMins * 60),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performScheduledScreenshot() }
        }
    }

    private func scheduleTimers() {
        scheduleScreenshotTimer()

        scheduleNextHeartbeat()
        scheduleNextCommandPoll()
        scheduleIdleActivityMonitor()

        // 定期拉取配置，使家长在后端的开启/撤销近实时生效，并让状态变化对孩子端可见
        configTimer?.invalidate()
        configTimer = scheduleCommonModeTimer(interval: 60, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.pollConfigForChildVisibility() }
        }
    }

    /// 心跳定时器自我重排：活跃态用 heartbeatActiveSeconds（默认 60s），空闲态改用
    /// heartbeatIdleSeconds（默认 900s/15 分钟）。此前是固定间隔的 repeating Timer，
    /// 空闲时只是心跳里的 eventType 换成 IDLE，触发频率从未真正降下来。
    private func scheduleNextHeartbeat() {
        heartbeatTimer?.invalidate()
        let interval: TimeInterval = wasIdle
            ? TimeInterval(client.config.heartbeatIdleSeconds)
            : TimeInterval(client.config.bound ? client.config.heartbeatActiveSeconds : max(client.config.heartbeatActiveSeconds, 300))
        heartbeatTimer = scheduleCommonModeTimer(interval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previouslyIdle = self.wasIdle
                let isIdle = self.client.isIdle
                let transition = ActivityStateTransition.resolve(previouslyIdle: previouslyIdle, isIdle: isIdle)
                if transition == .resumed {
                    self.handleResume(event: .resume)
                    return
                }

                await self.client.sendHeartbeat(event: isIdle ? .idle : .heartbeat)
                self.wasIdle = isIdle
                self.scheduleNextHeartbeat()
                if isIdle {
                    self.scheduleIdleActivityMonitor()
                } else {
                    self.stopIdleActivityMonitor()
                }
                self.triggerImmediateCommandPollIfNeeded()
            }
        }
    }

    /// 命令轮询自我重排：活跃态 30 秒一次，空闲态降到 5 分钟一次。
    private func scheduleNextCommandPoll() {
        commandTimer?.invalidate()
        guard client.config.bound else { return }
        let interval: TimeInterval = wasIdle ? 300 : 30
        commandTimer = scheduleCommonModeTimer(interval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.client.pollCommands()
                await MainActor.run { self.scheduleNextCommandPoll() }
            }
        }
    }

    /// 心跳/配置响应里如果带回 hasPendingCommand=true，立即触发一次命令轮询，
    /// 不等下一次定时轮询窗口，缩短"测试截图命令"从下发到执行的延迟。
    private func triggerImmediateCommandPollIfNeeded() {
        guard client.config.bound, client.config.hasPendingCommand else { return }
        commandTimer?.invalidate()
        Task {
            await client.pollCommands()
            await MainActor.run { self.scheduleNextCommandPoll() }
        }
    }

    /// 近实时拉取配置：一旦家长开启或撤销截图，立即更新常驻指示并通知孩子端。
    private func pollConfigForChildVisibility() async {
        // 补发的兜底触发点（每 60 秒一次）。前两个触发点是网络路径翻转和实时心跳成功，
        // 但两者都可能长时间不发生：路径一直 satisfied（强制门户/后端故障），而心跳如果
        // 也一直失败就永远没有"成功"可言。有这一条兜底，队列不会因为错过某个边沿而
        // 无限期滞留——这是旧实现最主要的缺陷（补发只挂在 NWPathMonitor 一个触发点上）。
        Task { await client.startBackfillIfNeeded() }

        let boundBefore = client.config.bound
        let invalidBefore = client.credentialsInvalid
        let before = client.config.screenshotEnabled
        // 记录旧的截图间隔，用于判断是否需要在配置变化后重排定时截图计时器
        let intervalBefore = client.config.screenshotIntervalMins
        // 凭据失效时签名通道全断，config 轮询收不到任何信号（包括解绑）。register 不签名：
        // 家长解绑后，后端会重新接受本机 secret（未绑定设备允许换钥），凭据在这里自动恢复，
        // 随后回到常规配置轮询——不需要重启客户端。
        if client.credentialsInvalid {
            await client.register()
        }
        var changed = false
        if !client.credentialsInvalid {
            changed = await client.refreshConfig().changed
        }
        await reportWebFilterStatus()
        let boundChanged = client.config.bound != boundBefore
        let credentialsChanged = client.credentialsInvalid != invalidBefore
        guard changed || boundChanged || credentialsChanged else { return }
        let after = client.config.screenshotEnabled
        await MainActor.run {
            // 60 秒配置轮询是时间约定的兜底同步路径——门铃丢失、或家长在设备离线期间
            // 操作过（改约/中断）都靠它最终追上。syncTimeSessionState 内部会自行判断
            // sessionId 是否真的变了，这里无脑调用即可。
            syncTimeSessionState()
            rebuildMenu()
            updateStatusItemAppearance()
            triggerImmediateCommandPollIfNeeded()
            if boundChanged {
                // 心跳/命令轮询的节奏依赖 bound，翻转后立即切换调度
                scheduleTimers()
                // 家长在仪表盘侧完成绑定（未经过本机 startBindDetectionBurst 那条路径时）
                // 也要强制恢复开机自启，抵消未绑定期间可能的关闭
                if client.config.bound {
                    enforceLaunchAtLoginOnBind()
                    warmAutomationConsentIfNeeded()
                }
            } else if client.config.screenshotIntervalMins != intervalBefore {
                // 关键修复：家长在仪表盘改了截图间隔后，之前这里只更新了 config 值、
                // 却没有重排 screenshotTimer，导致定时截图仍按旧间隔触发——"关于"窗口
                // 显示的新间隔与实际截图节奏对不上，家长以为客户端没遵循仪表盘设置。
                // 现在检测到间隔变化就按新值重排这一个计时器。
                scheduleScreenshotTimer()
                AuditLog.record("SCREENSHOT_INTERVAL_UPDATED mins=\(client.config.screenshotIntervalMins) source=remote")
            }
            if boundChanged && !client.config.bound {
                AuditLog.record("DEVICE_UNBOUND 家长已在仪表盘解除本设备的守护关系")
                postLocalNotice(
                    title: Localization.string(zh: "守护关系已解除", en: "Guardian binding removed"),
                    body: Localization.string(
                        zh: "家长已在仪表盘解绑本设备，守护采集已停止。可随时重新绑定。",
                        en: "Your parent unbound this Mac on the dashboard; guardian reporting has stopped. You can re-bind at any time."
                    )
                )
            }
            if after != before {
                AuditLog.record("SCREENSHOT_TOGGLE state=\(after ? "ENABLED" : "DISABLED") source=remote")
                // 每次开关翻转都界定了一段新的"截图开着"时间段，把缺权限提醒的节流状态
                // 也一并复位——避免上一段时间已经提醒过，这段新的却因为 flag 还是 true
                // 而永远不再提醒（见 onScreenshotMissingPermission）。
                missingPermissionNoticeShown = false
                // 家长刚打开截图这一刻，如果本机恰好还没给屏幕录制权限，顺带在这条已有的
                // 通知里提一句——这个触发点本来就只在开关真正翻转时响一次一次性的，不需要
                // 额外节流。跟 onScreenshotMissingPermission 是两条独立的提醒：这条只在
                // "刚打开开关"那一刻可能触发，那条是"开着但一直缺权限"期间、自动截图
                // 每次静默失败都可能触发（但被 missingPermissionNoticeShown 节流成一次）。
                let missingPermission = after && !checkScreenRecordingPermission()
                postLocalNotice(
                    title: after
                        ? Localization.string(zh: "家长已开启截图", en: "Parent turned screenshots ON")
                        : Localization.string(zh: "家长已关闭截图", en: "Parent turned screenshots OFF"),
                    body: after
                        ? (missingPermission
                            ? Localization.string(
                                zh: "家长现在可以远程截屏，但本机还没有屏幕录制权限，截图暂时不会生效。请点击菜单栏「关于 BigDaddy…」里的「⚠️ 前往设置授权」完成设置。",
                                en: "Your parent can now capture screenshots, but this Mac hasn't granted Screen Recording permission yet, so captures won't work. Open “About BigDaddy…” from the menu bar and tap “⚠️ Open Settings” to finish setup."
                              )
                            : Localization.string(zh: "家长现在可以远程截屏，本机会持续记录每一次截图。",
                                                  en: "Your parent can now capture screenshots; every capture is logged on this Mac."))
                        : Localization.string(zh: "截图功能已停止。",
                                              en: "Screenshot capture has been turned off.")
                )
            }
        }
    }

    // MARK: - 时间约定（家长设定的可用时长）

    /// 时间约定状态同步的统一入口。三处调用：60 秒配置轮询的兜底对比（changed 为真时）、
    /// SYNC_TIME_SESSION 门铃触发的即时刷新、系统唤醒后的强制重新校准。
    ///
    /// 无论 sessionId 是否变化，都会用当前 config.timeSession.remainingSeconds 重新计算
    /// timeSessionDeadline——这是"唤醒后重新定锚"那条路径真正需要的效果（见
    /// handleResumeFromSystemEvent 的注释）。只有 sessionId 确实变化（新开/被替换/
    /// 被中断/清空）时，才触发里程碑重置、计时器重启、旗帜展示/隐藏、本机审计记录这些
    /// "一次性"副作用，避免每次配置轮询都重复播放"会话开始"的下拉动画。
    private func syncTimeSessionState() {
        let current = client.config.timeSession
        let sessionChanged = current?.sessionId != trackedTimeSessionId
        // 本地已判过到点、服务端尚未确认的那个会话：它在配置里仍然存在（remainingSeconds=0），
        // 但对客户端来说已经处理完毕，不能再被当成"还在进行"去重新定锚或重启计时器。
        let awaitingExpiryConfirmation = current != nil && current?.sessionId == locallyExpiredSessionId

        if let session = current, !awaitingExpiryConfirmation {
            timeSessionDeadline = ProcessInfo.processInfo.systemUptime + Double(session.remainingSeconds)
        } else if current == nil {
            timeSessionDeadline = nil
        }
        // awaitingExpiryConfirmation 时刻意不动 timeSessionDeadline：
        // handleTimeSessionReachedZero 已经把它清成 nil，重新按 remainingSeconds=0 定锚会
        // 让它变成"此刻就到点"的非 nil 值，下一次 tick 又触发一遍到点处理。

        guard sessionChanged else {
            // 会话身份没变——多半是唤醒后的重新定锚，或一次无关变化触发的兜底轮询。
            // 计时器按幂等方式重新确保仍在运行；菜单项文字顺手刷新一次。
            if timeSessionDeadline != nil {
                scheduleTimeSessionTimer()
            }
            refreshTimeSessionMenuItemText()
            return
        }

        let previousSessionId = trackedTimeSessionId
        // 服务端刚刚确认了本地早已判过的那次自然到点：这不是家长中断，闪烁提醒也正在
        // 进行中，两者都不该被下面的"清空"分支按中断处理。
        let confirmingLocalExpiry = current == nil
            && previousSessionId != nil
            && previousSessionId == locallyExpiredSessionId
        trackedTimeSessionId = current?.sessionId
        timeSessionMilestonesFired.removeAll()
        timeSessionTimer?.invalidate()
        timeSessionTimer = nil

        if let session = current {
            // 新会话（含"旧的还在闪烁时家长又设了一段"）：本地到点标记随之作废
            locallyExpiredSessionId = nil
            AuditLog.record("TIME_SESSION_STARTED grantedSeconds=\(session.grantedSeconds)")
            timeSessionMilestonesFired.insert(.started)
            scheduleTimeSessionTimer()
            // present 内部会先把面板重置回倒计时形态（含摘掉「我知道了」按钮、恢复
            // ignoresMouseEvents），接替上一次约定还没走完的到点提醒。
            presentTimeSessionFlag(session: session, autoDismissAfter: 4)
        } else if confirmingLocalExpiry {
            // 让归零时启动的那 5 分钟闪烁自然走完：既不在这里打断，也不记 CANCELLED
            // （那会把一次自然到点误报成家长中断，本机守护记录里就多出一条假事件）。
            locallyExpiredSessionId = nil
        } else {
            timeFlag?.dismiss()
            locallyExpiredSessionId = nil
            if previousSessionId != nil {
                // 只记"服务端已不再报告这个约定"这个客户端真正观测到的事实，不写原因。
                //
                // 客户端在这里**无法区分**两种成因，它们在本地看来完全同形（会话凭空消失、
                // 且没有本地归零事件）：① 家长在仪表盘主动中断；② 约定在 Mac 睡眠期间
                // 自然到点——睡眠时 1 秒 tick 不运行，本地永远没机会判归零，醒来时服务端
                // 早已清掉了它。此前这里写死 CANCELLED，等于把情况 ② 在孩子可见的守护记录
                // 里谎报成"家长中断了约定"。准确的成因（TIMER_EXPIRED / TIMER_CANCELLED）
                // 由服务端审计流水记录、在家长仪表盘里可查，本机记录只需诚实描述所见。
                AuditLog.record("TIME_SESSION_ENDED source=remote 服务端已不再报告进行中的约定")
            }
        }
        rebuildMenu()
    }

    /// 本地倒计时到 0 时触发：不等服务端确认，直接进入"到点"视觉状态。真正的到点判定
    /// 在服务端（BigDaddyTimeSessionScheduler 每 30 秒扫一次并通知家长），这里只是本地
    /// 渲染先跟上，好让孩子在归零那一秒就看到提醒，而不是等最多 30 秒。
    ///
    /// **保留** trackedTimeSessionId、另记一个 locallyExpiredSessionId：这两件事一起，
    /// 才能让接下来最长 30 秒窗口内的每一次配置轮询都识别出"这个会话我已经处理完了"。
    /// 曾经的写法是在这里把 trackedTimeSessionId 清成 nil，指望服务端确认时按
    /// "nil == nil 身份没变"短路——但那个窗口里服务端返回的**仍是这个会话本身**
    /// （status 还是 ACTIVE、remainingSeconds 被算成 0），于是 sessionChanged 判定为真，
    /// 走进"新会话"分支：记一条假的 TIME_SESSION_STARTED、掐掉正在进行的闪烁、
    /// 换成一个 0:00 的倒计时旗帜，下一次 tick 又归零一次、再记一条 TIME_SESSION_EXPIRED
    /// 并把 5 分钟闪烁重新计时。
    private func handleTimeSessionReachedZero() {
        timeSessionTimer?.invalidate()
        timeSessionTimer = nil
        timeSessionDeadline = nil
        let expiredSessionId = trackedTimeSessionId
        locallyExpiredSessionId = expiredSessionId
        AuditLog.record("TIME_SESSION_EXPIRED")
        // 到点提醒。此前这里只是让已经在屏幕上的旗帜开始闪烁，读数停留在最后一次 tick
        // 算出的 "0:01"（`.rounded(.up)` 让任何不足一秒的余量都进位成 1）——孩子看到的
        // 是一个"还剩一秒"却再也不动的读数。presentTimeUp 显式写 0:00，并且在面板已被
        // 自动收回时重新弹出来。
        if let statusItem, let session = client.config.timeSession {
            let flag = timeFlag ?? TimeAgreementFlag()
            timeFlag = flag
            bindAcknowledgeHandler(to: flag, sessionId: expiredSessionId)
            flag.presentTimeUp(anchor: statusItem, note: session.note, duration: 5 * 60)
        }
        rebuildMenu()
    }

    /// 把「我知道了」接到"收回提醒 + 上报回执"上。
    ///
    /// 这一下是整条时间约定链路里**唯一**由孩子本人发出的信号：旗帜可能弹在一台没人的
    /// 电脑前（firstShownAt 只证明它显示过），而按钮被按下必定意味着孩子此刻就在。所以
    /// 它值得单独走一趟回执、在家长端留一条 TIMER_ACKNOWLEDGED——不是为了监视这一下点击，
    /// 而是让家长知道"提醒确实到人了"，不必再去猜孩子是没看见还是装作没看见。
    private func bindAcknowledgeHandler(to flag: TimeAgreementFlag, sessionId: String?) {
        flag.onAcknowledge = { [weak self] in
            AuditLog.record("TIME_SESSION_ACKNOWLEDGED 孩子点了「我知道了」")
            guard let self, let sessionId else { return }
            Task { await self.client.reportTimeSessionAcknowledged(sessionId) }
        }
    }

    /// 驱动倒计时/里程碑检查的 1 秒计时器。用 .common 模式的手动 Timer（原因见
    /// scheduleCommonModeTimer 的注释）：家长弹出的弹窗不该让倒计时的最后 30 秒 sticky
    /// 显示停摆。
    private func scheduleTimeSessionTimer() {
        timeSessionTimer?.invalidate()
        guard timeSessionDeadline != nil else { return }
        timeSessionTimer = scheduleCommonModeTimer(interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.timeSessionTick() }
        }
    }

    private func timeSessionTick() {
        guard let deadline = timeSessionDeadline, let session = client.config.timeSession else { return }
        let remaining = max(0, Int((deadline - ProcessInfo.processInfo.systemUptime).rounded(.up)))
        refreshTimeSessionMenuItemText()

        if remaining <= 0 {
            handleTimeSessionReachedZero()
            return
        }

        // 每个里程碑只在"约定本身够长、这个提前量才有意义"时才生效：一个 3 分钟的约定
        // 不该在开始没多久就弹出"剩余 5 分钟"的提醒——那从来就不是它的剩余量。
        let granted = session.grantedSeconds
        if granted >= 600, !timeSessionMilestonesFired.contains(.halfway), remaining <= granted / 2 {
            timeSessionMilestonesFired.insert(.halfway)
            presentTimeSessionFlag(session: session, remainingOverride: remaining, autoDismissAfter: 3)
        }
        if granted > 300, !timeSessionMilestonesFired.contains(.fiveMinutes), remaining <= 300 {
            timeSessionMilestonesFired.insert(.fiveMinutes)
            presentTimeSessionFlag(session: session, remainingOverride: remaining, autoDismissAfter: 3)
        }
        if granted > 60, !timeSessionMilestonesFired.contains(.oneMinute), remaining <= 60 {
            timeSessionMilestonesFired.insert(.oneMinute)
            presentTimeSessionFlag(session: session, remainingOverride: remaining, autoDismissAfter: 3)
        }
        if !timeSessionMilestonesFired.contains(.thirtySeconds), remaining <= 30 {
            timeSessionMilestonesFired.insert(.thirtySeconds)
            // sticky：autoDismissAfter 传 nil，一直显示到归零
            presentTimeSessionFlag(session: session, remainingOverride: remaining, autoDismissAfter: nil)
        } else if timeSessionMilestonesFired.contains(.thirtySeconds) {
            // 已经进入 sticky 阶段：面板保持展示，仍需要每秒把数字刷新掉
            timeFlag?.update(remainingSeconds: remaining, note: session.note)
        }
    }

    /// 展示旗帜并顺带上报"孩子已看到"。每个里程碑都会调用一次——重复上报无害
    /// （后端 markTimeSessionShown 只记第一次），换来的是代码不必特判"只在第一次上报"。
    private func presentTimeSessionFlag(session: TimeSession, remainingOverride: Int? = nil, autoDismissAfter: TimeInterval?) {
        guard let statusItem else { return }
        let remaining = remainingOverride ?? session.remainingSeconds
        let flag = timeFlag ?? TimeAgreementFlag()
        timeFlag = flag
        bindAcknowledgeHandler(to: flag, sessionId: session.sessionId)
        flag.present(anchor: statusItem, remainingSeconds: remaining, note: session.note, autoDismissAfter: autoDismissAfter)
        let sessionId = session.sessionId
        Task { await client.reportTimeSessionShown(sessionId) }
    }

    private func refreshTimeSessionMenuItemText() {
        guard let item = timeSessionMenuItem, let session = client.config.timeSession else { return }
        // deadline 为 nil = 本地已判过到点（handleTimeSessionReachedZero 清掉了它）。
        // 这条菜单项本该随之消失，但如果菜单此刻正开着，重建被推迟到关闭之后——
        // 那段时间里显示 0:00 才诚实，继续挂着最后那个非零读数会和已经弹出的到点
        // 提醒自相矛盾。
        let remaining = timeSessionDeadline
            .map { max(0, Int(($0 - ProcessInfo.processInfo.systemUptime).rounded(.up))) } ?? 0
        item.title = Self.timeSessionMenuTitle(remaining: remaining, grantedSeconds: session.grantedSeconds)
    }

    private static func timeSessionMenuTitle(remaining: Int, grantedSeconds: Int) -> String {
        let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
        let grantedMinutes = grantedSeconds / 60
        return Localization.string(
            zh: "⏳ 时间约定剩余 \(clock)（共 \(grantedMinutes) 分钟）",
            en: "⏳ Time left: \(clock) (of \(grantedMinutes) min)"
        )
    }

    /// "关于"窗口"时间约定"行的当前文案，nil 表示当下没有进行中的约定（该行不渲染）。
    private func currentTimeSessionRemainingText() -> String? {
        guard let session = client.config.timeSession, let deadline = timeSessionDeadline else { return nil }
        let remaining = max(0, Int((deadline - ProcessInfo.processInfo.systemUptime).rounded(.up)))
        let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
        return Localization.string(
            zh: "\(clock)（共 \(session.grantedSeconds / 60) 分钟）",
            en: "\(clock) (of \(session.grantedSeconds / 60) min)"
        )
    }

    private func performScheduledScreenshot() {
        guard !client.isIdle else { return }
        Task {
            await client.captureAndSendScreenshot(reason: "scheduled")
            await client.sendHeartbeat(event: .heartbeat)
        }
    }

    /// 客户端没有独立的 .icns，NSAlert 默认回落到系统通用可执行文件图标，观感像
    /// "来路不明的程序"。绑定相关的关键弹窗统一用盾牌图标。
    private func applyShieldIcon(to alert: NSAlert) {
        alert.icon = ShieldIcon.image(pointSize: 64)
    }

    @objc private func showDeviceBindCode() {
        guard checkAndRequestPermissions() else { return }

        Task {
            await client.register()
            await MainActor.run {
                let fingerprint = client.identity.fingerprint
                guard let initialToken = client.bindToken else {
                    let errorAlert = NSAlert()
                    errorAlert.alertStyle = .warning
                    errorAlert.messageText = Localization.string(zh: "无法获取绑定码", en: "Cannot get bind code")
                    errorAlert.informativeText = Localization.string(
                        zh: "请检查网络连接后重试。",
                        en: "Please check your network connection and try again."
                    )
                    self.applyShieldIcon(to: errorAlert)
                    errorAlert.runModal()
                    return
                }
                let alert = NSAlert()
                alert.messageText = Localization.string(zh: "设备绑定验证", en: "Device Binding Verification")
                alert.informativeText = Localization.string(
                    zh: "请家长登录仪表盘，输入下方的 6 位绑定码完成绑定。家长就在旁边时，可点击「在本机打开仪表盘」直接在这台电脑上操作。",
                    en: "Ask your parent to sign in to the dashboard and enter the 6-digit bind code below. If your parent is nearby, click \"Open Dashboard on This Mac\" to finish binding right here."
                )
                self.applyShieldIcon(to: alert)

                let accessory = self.createBindCodeAccessoryView(fingerprint: fingerprint, initialToken: initialToken)
                alert.accessoryView = accessory

                alert.addButton(withTitle: Localization.string(zh: "在本机打开仪表盘", en: "Open Dashboard on This Mac"))
                alert.addButton(withTitle: Localization.string(zh: "复制绑定信息", en: "Copy Binding Info"))
                alert.addButton(withTitle: Localization.string(zh: "关闭", en: "Close"))

                // 初始化倒计时
                self.countdownSeconds = 300
                self.bindTokenRefreshing = false
                self.updateCountdownLabelText()

                // 本弹窗的 runModal() 是从主 actor 任务内部调起的（Task → MainActor.run），
                // 外层 dispatch 块在弹窗关闭前不会返回，嵌套运行循环无法再入排空主队列——
                // 这种弹窗期间 Task { @MainActor } / DispatchQueue.main 一律不执行（实测
                // 验证；从菜单动作直接调起的弹窗如安全退出则不受此限），之前 Timer(block:)
                // 里包 Task { @MainActor } 的写法因此冻结在 05:00。selector 形式的 Timer
                // 由运行循环直接回调、不经过主队列，配合 .common 模式（包含 modal panel
                // 模式）在弹窗打开期间照常触发。
                self.countdownTimer?.invalidate()
                let timer = Timer(
                    timeInterval: 1.0, target: self, selector: #selector(self.bindCountdownTick),
                    userInfo: nil, repeats: true
                )
                RunLoop.main.add(timer, forMode: .common)
                self.countdownTimer = timer

                // 运行 Alert Modal
                let response = alert.runModal()

                // Modal 结束，销毁计时器
                self.countdownTimer?.invalidate()
                self.countdownTimer = nil

                if response == .alertFirstButtonReturn {
                    // 在本机默认浏览器打开 dashboard 绑定页（带指纹与当前绑定码，页面
                    // 自动预填），家长在孩子电脑上登录确认即可，不需要两台电脑来回跑。
                    NSWorkspace.shared.open(self.client.dashboardBindURL())
                } else if response == .alertSecondButtonReturn {
                    let currentToken = self.digitLabels.map { $0.stringValue }.joined()
                    let bindPage = self.client.dashboardBaseURL.appendingPathComponent("bind").absoluteString
                    let bindText = Localization.string(
                        zh: "BigDaddy 绑定码：\(currentToken)（5 分钟内有效）。请把这条信息发给家长：打开 \(bindPage) 输入绑定码即可完成绑定。",
                        en: "BigDaddy bind code: \(currentToken) (valid for 5 minutes). Send this to your parent — open \(bindPage) and enter the code to finish binding."
                    )
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bindText, forType: .string)
                    self.postLocalNotice(
                        title: Localization.string(zh: "绑定信息已复制", en: "Binding info copied"),
                        body: Localization.string(
                            zh: "发送给家长，家长在仪表盘输入绑定码即可完成绑定。",
                            en: "Send it to your parent — they can finish binding by entering the code on the dashboard."
                        )
                    )
                }
                // 弹窗关闭、绑定码已就绪：无论家长在本机还是别处输码，都启动快检测，
                // 让"绑定成功"近实时反馈（"关闭"按钮也启动，家长可能仍会去输码）
                self.startBindDetectionBurst()
            }
        }
    }

    private func createBindCodeAccessoryView(fingerprint: String, initialToken: String) -> NSView {
        // NSAlert 按 accessoryView 的 frame 预留空间，外层必须是带明确 frame 的普通 NSView
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 10
        container.alignment = .centerX
        container.translatesAutoresizingMaskIntoConstraints = false

        parentView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: parentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: parentView.trailingAnchor)
        ])

        // 1. 水平数字框的 StackView
        let digitsStack = NSStackView()
        digitsStack.orientation = .horizontal
        digitsStack.spacing = 8
        digitsStack.alignment = .centerY
        digitsStack.distribution = .fill
        // 不让 digitsStack 被 container 拉满宽度，保持内容固有尺寸居中
        digitsStack.setHuggingPriority(.required, for: .horizontal)
        
        self.digitLabels.removeAll()
        
        let paddedToken = initialToken.padding(toLength: 6, withPad: "0", startingAt: 0)
        let chars = Array(paddedToken)
        
        for i in 0..<6 {
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 1.0
            box.borderColor = NSColor.separatorColor
            box.cornerRadius = 6.0
            box.fillColor = NSColor.controlBackgroundColor
            box.wantsLayer = true
            
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 30).isActive = true
            box.heightAnchor.constraint(equalToConstant: 38).isActive = true
            
            let label = NSTextField()
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.alignment = .center
            label.font = NSFont.boldSystemFont(ofSize: 18)
            label.textColor = NSColor.labelColor
            label.stringValue = String(chars[i])

            label.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(label)

            // 同一套"撑满而非居中"修复，与 exit 验证码方框保持一致，避免数字在方框内
            // 因 intrinsic size 计算而被裁切/偏移。
            if let contentView = box.contentView {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    label.topAnchor.constraint(equalTo: contentView.topAnchor),
                    label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
                ])
            }

            digitsStack.addArrangedSubview(box)
            self.digitLabels.append(label)
        }
        
        // 2. 倒计时文本框
        let countdownField = NSTextField()
        countdownField.isEditable = false
        countdownField.isSelectable = false
        countdownField.isBordered = false
        countdownField.drawsBackground = false
        countdownField.alignment = .center
        countdownField.font = NSFont.systemFont(ofSize: 11)
        countdownField.textColor = NSColor.secondaryLabelColor
        self.countdownLabel = countdownField

        // 3. 设备识别码文本框
        let displayId: String
        if fingerprint.count > 12 {
            let head = fingerprint.prefix(6)
            let tail = fingerprint.suffix(6)
            displayId = "\(head)...\(tail)".uppercased()
        } else {
            displayId = fingerprint.uppercased()
        }
        
        let deviceIdField = NSTextField()
        deviceIdField.isEditable = false
        deviceIdField.isSelectable = true
        deviceIdField.isBordered = false
        deviceIdField.drawsBackground = false
        deviceIdField.alignment = .center
        deviceIdField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        deviceIdField.textColor = NSColor.tertiaryLabelColor
        deviceIdField.stringValue = Localization.string(
            zh: "设备识别码: \(displayId)",
            en: "Device ID: \(displayId)"
        )
        
        container.addArrangedSubview(digitsStack)
        container.addArrangedSubview(countdownField)
        container.addArrangedSubview(deviceIdField)

        return parentView
    }

    /// 绑定弹窗的每秒 tick（selector 形式，modal 期间照常触发，见 showDeviceBindCode 注释）。
    /// 归零后静默获取新绑定码并复位倒计时。
    @objc private func bindCountdownTick() {
        // 先取刷新结果信箱：后台网络任务把新绑定码放进来，由 tick 在主线程应用到界面
        if let refreshed = bindTokenMailbox.take() {
            bindTokenRefreshing = false
            countdownSeconds = 300
            updateDigitBoxes(with: refreshed)
            updateCountdownLabelText()
            return
        }
        if countdownSeconds > 0 {
            countdownSeconds -= 1
            updateCountdownLabelText()
            return
        }
        guard !bindTokenRefreshing else { return }
        bindTokenRefreshing = true
        countdownLabel?.stringValue = Localization.string(zh: "正在获取新的绑定码…", en: "Fetching a new bind code…")
        // 本弹窗 modal 期间主队列不排空（runModal 从主 actor 任务调起，见
        // showDeviceBindCode 注释），网络结果不能用 Task { @MainActor } /
        // DispatchQueue.main 送回界面。detached 任务只负责拿新码并写入信箱，
        // 应用到 UI 由下一次 tick 完成。
        let mailbox = bindTokenMailbox
        let oldToken = self.client.bindToken
        Task.detached { [client = self.client] in
            await client.register()
            let newToken = client.bindToken
            // 只有 token 真正发生变化才视为刷新成功；register 失败时 bindToken 不会被清空，
            // 仍保持旧值，此时不应把过期的旧 token 当作新 token 重新展示。
            // 刷新失败时也需要写入 mailbox（空字符串），否则 bindTokenRefreshing 永远为 true，
            // UI 倒计时卡死。
            if let token = newToken, token != oldToken {
                mailbox.put(token)
            } else {
                // 刷新失败：写空串让 tick 解除 refreshing 状态并复位倒计时，
                // 界面保留旧的 token 显示（虽然可能已过期，但优于卡死）
                mailbox.put(oldToken ?? "")
            }
        }
    }

    private func updateDigitBoxes(with token: String) {
        let paddedToken = token.padding(toLength: 6, withPad: "0", startingAt: 0)
        let chars = Array(paddedToken)
        for i in 0..<min(chars.count, digitLabels.count) {
            digitLabels[i].stringValue = String(chars[i])
        }
    }

    @objc private func showBindCodeInput() {
        // 之前只有"扫码绑定"这条路径会检查屏幕录制/辅助功能权限，从这里绑定的设备
        // 会在毫无权限提示的情况下直接完成绑定，后续截图静默失败。两条绑定路径都要检查。
        guard checkAndRequestPermissions() else { return }

        let alert = NSAlert()
        alert.messageText = Localization.string(
            zh: "输入家长提供的绑定码",
            en: "Enter the bind code from parent"
        )
        alert.informativeText = Localization.string(
            zh: "请在家长仪表盘获取 6 位绑定码",
            en: "Get the 6-digit bind code from the dashboard"
        )
        applyShieldIcon(to: alert)


        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        inputField.placeholderString = "000000"
        inputField.alignment = .center
        inputField.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        alert.accessoryView = inputField

        alert.addButton(withTitle: Localization.string(zh: "确认绑定", en: "Confirm Bind"))
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))

        // 打开即可直接输入，不用先手动点一下输入框。同 quitWithPassword 里的说明：
        // initialFirstResponder 会被 NSAlert 自己的展示逻辑覆盖，改成在模态运行循环里
        // 异步抢一次焦点。
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(inputField)
        }

        if alert.runModal() == .alertFirstButtonReturn {
            let code = inputField.stringValue.trimmingCharacters(in: .whitespaces)
            guard code.count == 6, code.allSatisfy({ $0.isNumber }) else {
                let errorAlert = NSAlert()
                errorAlert.messageText = Localization.string(zh: "绑定码格式错误", en: "Invalid bind code format")
                errorAlert.informativeText = Localization.string(zh: "请输入 6 位数字", en: "Please enter 6 digits")
                errorAlert.runModal()
                return
            }
            
            Task {
                do {
                    let success = try await client.bindWithCode(code)
                    if success {
                        _ = await client.refreshConfig()
                        // 绑定成功：立即发送一次心跳，让后端即时感知设备上线
                        await client.sendHeartbeat(event: .start)
                        rebuildMenu()
                        scheduleTimers()
                        await MainActor.run {
                            let successAlert = NSAlert()
                            successAlert.messageText = Localization.string(zh: "绑定成功！", en: "Bind Successful!")
                            successAlert.informativeText = Localization.string(zh: "设备已与家长账户关联", en: "Device is now linked to parent account")
                            successAlert.runModal()
                        }
                    } else {
                        await MainActor.run {
                            let errorAlert = NSAlert()
                            errorAlert.messageText = Localization.string(zh: "绑定失败", en: "Bind Failed")
                            errorAlert.informativeText = Localization.string(zh: "绑定码无效或已过期", en: "Invalid or expired bind code")
                            errorAlert.runModal()
                        }
                    }
                } catch {
                    await MainActor.run {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = Localization.string(zh: "绑定失败", en: "Bind Failed")
                        errorAlert.informativeText = error.localizedDescription
                        errorAlert.runModal()
                    }
                }
            }
        }
    }

    private func updateCountdownLabelText() {
        let minutes = countdownSeconds / 60
        let seconds = countdownSeconds % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)
        countdownLabel?.stringValue = Localization.string(
            zh: "绑定码将在 \(timeString) 后自动更新",
            en: "Bind code auto-updates in \(timeString)"
        )
    }

    @objc private func sendScreenshotNow() {
        // 同 pollCommands 里对"测试截图命令"的处理：本机菜单栏/"关于"窗口的"测试截图"
        // 是另一条完全独立、不经过后端命令通道的路径，之前没有同步刷新配置。如果刚在
        // 仪表盘保存了新的压缩质量/截图宽度就立刻在孩子的 Mac 上点这个按钮测试，客户端
        // 手上可能还是保存前的旧配置（最长要等 60 秒的配置轮询才会同步），效果对不上。
        Task {
            _ = await client.refreshConfig()
            await client.captureAndSendScreenshot(reason: "manual")
        }
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate（静默下载完成后，等设备空闲了由本 App 自己静默装上）
    //
    // Sparkle 的协议不带 actor 隔离，而 AppDelegate 整体是 @MainActor，实现只能声明成
    // nonisolated；要读写 @MainActor 状态就用 Task { @MainActor in } 跳回主线程。
    // （不用 `@MainActor SPUUpdaterDelegate` 那种隔离一致性写法，CI 的工具链版本还不认识
    // 这个语法，会直接编译失败。）

    /// 后台已经静默下载好一个更新、Sparkle 准备把它排进"等 App 退出时再装"时回调。
    ///
    /// 返回 true = 安装这一步由我们接管：Sparkle 停掉当前及后续的检查周期，把
    /// immediateInstallHandler 交给我们，什么时候调它就什么时候装好并重启，全程不出现
    /// Sparkle 自己的任何界面。我们要的正是这个——全程静默，不弹任何询问框，等设备空闲
    /// 了才调用它（见 scheduleIdleInstallCheck）。
    ///
    /// 代价是"停掉后续检查周期"：在我们调用 immediateInstallHandler 之前不会再有新的
    /// 回调。但兜底始终存在——文件已经在本机下载好了，这台机器任何一次退出/关机，
    /// Sparkle 都会把它装上（见该方法文档：In either case Sparkle will always attempt
    /// to install the update when the app terminates）。
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            self.noteUpdateDownloaded(version: version, install: immediateInstallHandler)
        }
        return true
    }

    /// Sparkle 已经装好新版本、马上要重启本 App 前的最后一次回调（此刻本进程还活着）。
    ///
    /// 必须在这里退休"墓碑"文件。Sparkle 结束本进程用的是 Apple Event quit，不是信号——
    /// installSignalHandlers 里那条 FORCE_KILL 路径不会被触发，走的是 applicationWillTerminate，
    /// 而那里是刻意留空的（SHUTDOWN 只在 quitWithPassword 里发），墓碑没人清。于是下次
    /// 启动时 prepareRuntime() 读到残留的墓碑，把这次**正常的更新重启**当成上次异常终止，
    /// 心跳带上 previousCrashAt，家长端凭空多出一条"守护进程异常退出"。
    ///
    /// 这里只退休墓碑、不补发心跳：更新重启既不是孩子走验证码的正常退出（SHUTDOWN），
    /// 也不是被强制关闭（FORCE_KILL），套用任何一个都是在向家长谎报。家长端看到的就是
    /// 十几秒的心跳间隔，随后新版本发来 START——如实反映"它重启了一次"。
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        AuditLog.record("UPDATE_INSTALL_RELAUNCH")
        BigDaddyClient.noteUpdateRestart()
    }

    /// 新版本已下载完毕：记下待安装状态，让下拉菜单/「关于」窗口冒出提示，并开始
    /// 等设备空闲。
    private func noteUpdateDownloaded(version: String, install: @escaping () -> Void) {
        pendingUpdateVersion = version
        pendingUpdateInstall = install
        AuditLog.record("UPDATE_DOWNLOADED version=\(version)")
        rebuildMenu()
        scheduleIdleInstallCheck()
    }

    /// 安装策略：静默、不弹任何询问框，等设备空闲了才装。
    ///
    /// 这是装在孩子设备上的监控客户端，"要不要装更新"这个判断本该由家长决定（通过
    /// 后台自动检查这件事本身），不该指望孩子看懂一个更新对话框、更不该让"稍后再说"
    /// 变成孩子拖更新的手段。等空闲再装是为了不在孩子正在用电脑时打断——虽然这个后台
    /// 进程重启只有几秒钟空窗，但能不打扰就不打扰。
    ///
    /// 用独立计时器而不是复用心跳计时器：职责不同（同 startOpenMenuTicking 的注释），
    /// 心跳节奏由服务端下发的活跃/空闲间隔决定、且可能变化，这里只想要"有待装更新期间，
    /// 定期看看孩子是不是已经离开了"，跟心跳节奏没有耦合关系。60 秒一次的粒度足够——
    /// 装上就立刻重启，晚个几十秒发现空闲不影响什么。
    private func scheduleIdleInstallCheck() {
        updateIdleInstallTimer?.invalidate()
        updateIdleInstallTimer = nil
        guard pendingUpdateInstall != nil else { return }
        if client.isIdle {
            installPendingUpdate()
            return
        }
        updateIdleInstallTimer = scheduleCommonModeTimer(interval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleIdleInstallCheck()
            }
        }
    }

    /// 装上已下载好的更新并重启本 App。空闲检测到点后自动调用；下拉菜单那条"有更新
    /// 待装"提示和「关于」窗口里的高亮按钮也走这条路径，供家长手动提前触发——点击本身
    /// 就是"现在就装"的明确信号，跳过等空闲这一步。
    @objc private func installPendingUpdate() {
        guard let install = pendingUpdateInstall else { return }
        updateIdleInstallTimer?.invalidate()
        updateIdleInstallTimer = nil
        pendingUpdateInstall = nil
        pendingUpdateVersion = nil
        AuditLog.record("UPDATE_INSTALLING")
        install()
    }

    /// 知情透明：向使用本机的孩子清楚说明这是什么、谁能看到、采集了什么、如何暂停。
    ///
    /// 这个弹窗的受众其实有两个：首次启动时读它的是孩子，但家长刚在孩子机器上装完、
    /// 人就站在旁边，所以家长也会读到。原先的文案是从隐私政策搬来的措辞（"法定监护人"
    /// "在你知情的前提下""你的知情权"）加上一串技术名词（"采集内容""活动应用"
    /// "使用摘要""只做中转""截图原图"），结果对两边都不好读——家长反馈"太专业看不懂"。
    /// 现在改成"孩子会问的问题 + 大白话回答"，术语全部换成日常说法。
    @objc private func showTransparencyInfo() {
        let alert = NSAlert()
        alert.messageText = Localization.string(
            zh: "这台电脑上装了什么？",
            en: "What's running on this Mac?"
        )
        // 采集说明随当前真实状态变化，避免"文案说没开、实际已开"的表里不一。
        // 这个弹窗在首次启动、尚未绑定时也会弹出（见 presentFirstRunDisclosureIfNeeded），
        // 而 screenshotEnabled 单独判断在"曾经绑定并开过截图、之后被解绑"这种情况下
        // 会残留 true（解绑只翻转 bound，见 refreshConfig 的注释）——不加 bound 这道
        // 门禁，孩子会被明确告知"截图现在是开着的"，而实际上（配合上面 captureAndSendScreenshot
        // 的 bound 门禁）这台未绑定的设备根本不会截图，是当着孩子的面撒谎。
        let shotEffectivelyOn = client.config.bound && client.config.screenshotEnabled
        let shotStatusZh = shotEffectivelyOn
            ? "截图现在是开着的——家长可以看到你的屏幕画面。每拍一次，这台电脑上都会弹通知告诉你，并且记进下面说的那个文件里。"
            : "截图现在是关着的，只记上面这些文字，不会拍你的屏幕。"
        let shotStatusEn = shotEffectivelyOn
            ? "Screenshots are on right now — your parent can see your screen. Every time one is taken, this Mac pops up a notice to tell you, and writes it into the file mentioned below."
            : "Screenshots are off right now. It only notes the text above; it does not capture your screen."
        alert.informativeText = Localization.string(
            zh: """
            爸爸妈妈在这台电脑上装了 BigDaddy。这不是偷偷装的——所以现在这个窗口才会弹出来告诉你。

            它记什么？
            你现在开着哪个应用、窗口标题上写着什么，比如"Safari — 某某网站"。它不看你打的字，也不读你的聊天内容。\(shotStatusZh)

            谁能看到？
            只有绑定这台电脑的那位家长。截图路过服务器的时候立刻就转走了，服务器上不留。

            你怎么知道它在干什么？
            屏幕最上面那一排里有个小盾牌，一直都在，你随时能点开。盾牌旁边什么都没有，就是没在截图；多出一个小圆点，就是截图开着；圆点变成一个圈，就是这一刻正在截图——扫一眼就知道现在是哪种。它做的每一件事都记在这台电脑上的一个文件里，点下面的按钮就能打开自己看。

            想暂停或者卸载？
            跟家长说一声。家长会在他那边生成一个一次性的数字码，你输进去就能退出。

            ——如果你是家长，而这就是你自己的电脑：BigDaddy 应该装在孩子的电脑上，装在这里不会有任何用。
            """,
            en: """
            Your parent installed BigDaddy on this Mac. It wasn't done behind your back — that's why this window is showing up right now.

            What does it note down?
            Which app you have open and what the window is called, like "Safari — some website". It doesn't see what you type, and it doesn't read your chats. \(shotStatusEn)

            Who can see it?
            Only the parent this Mac is linked to. Screenshots pass through the server and are sent straight on — nothing is kept there.

            How do you know what it's doing?
            There's a small shield in the strip along the very top of the screen. It's always there, and you can open it any time. Nothing next to the shield means no screenshots are being taken; a small dot means they're on; the dot turning into a ring means a screenshot is being taken right this moment — one glance tells you which. Everything it does is written into a file on this Mac — press the button below to open it and read it yourself.

            Want to pause it or take it off?
            Talk to your parent. They can generate a one-time code on their side, and typing it in lets you quit.

            — If you're a parent and this is your own computer: BigDaddy belongs on your child's computer. Installed here, it won't do anything useful.
            """
        )
        alert.addButton(withTitle: Localization.string(zh: "知道了", en: "Got it"))
        alert.addButton(withTitle: Localization.string(zh: "看看它都记了什么", en: "See what it has noted"))
        if alert.runModal() == .alertSecondButtonReturn {
            exportAuditLog()
        }
    }

    /// 家长把客户端装到了自己的电脑上时的自助纠错。只在未绑定态提供——一旦绑定过，
    /// 纠错就得走仪表盘解绑（会永久删除该设备历史），那条路必须由家长在仪表盘上走，
    /// 这里给不了捷径。
    @objc private func showWrongMacHelp() {
        // dashboardBaseURL 指向的是 dashboard 子域名（默认 dashboard.bigdaddy.mom），
        // 那里的根路径会直接 302 到登录页，没有下载入口——家长照着这段文字去孩子的
        // Mac 上打开它，看到的只会是一个登录表单，不是下载按钮，白跑一趟还更困惑。
        // 下载页在营销站根域名（bigdaddy.mom）上，从 dashboard 子域名剥掉 "dashboard."
        // 前缀就是它。本地开发环境的 localhost 只能代表当前这台 Mac，不能让孩子在另一台
        // Mac 上照抄，所以一律回落到生产官网。
        let dashboardHost = client.dashboardBaseURL.host ?? "dashboard.bigdaddy.mom"
        let dashboardPrefix = "dashboard."
        let marketingHost: String
        if Self.isLocalDashboardHost(dashboardHost) {
            marketingHost = "bigdaddy.mom"
        } else if dashboardHost.hasPrefix(dashboardPrefix) {
            marketingHost = String(dashboardHost.dropFirst(dashboardPrefix.count))
        } else {
            marketingHost = dashboardHost
        }
        let marketingURL = URL(string: "https://\(marketingHost)")!

        let alert = NSAlert()
        alert.messageText = Localization.string(
            zh: "BigDaddy 要装在孩子的电脑上",
            en: "BigDaddy belongs on your child's computer"
        )
        alert.informativeText = Localization.string(
            zh: """
            这台电脑上的 BigDaddy 还没有绑定，也就还没有开始记录任何东西——现在退出、删掉它，不会留下任何痕迹。

            正确的做法是：
            1. 在这台（你自己的）电脑上，把 BigDaddy 从「应用程序」里删掉就行。
            2. 到孩子的那台 Mac 上打开 \(marketingHost)，在那台电脑上下载安装。
            3. 装好后点它的菜单栏图标，拿到 6 位数字。
            4. 回到你自己的设备上，登录仪表盘，把那 6 位数字输进去。

            简单说：软件装在被守护的那台电脑上，你自己只要能打开仪表盘就够了。
            """,
            en: """
            BigDaddy on this Mac isn't linked to anyone yet, so it hasn't recorded a thing. Quit it and delete it now and nothing is left behind.

            Here's what to do instead:
            1. On this computer — your own — just drag BigDaddy out of Applications.
            2. Go to your child's Mac and open \(marketingHost) there to download and install it.
            3. Once it's running, click its menu bar icon to get a 6-digit number.
            4. Back on your own device, sign in to the dashboard and type those 6 digits in.

            In short: the app goes on the computer being looked after. All you need on your own device is the dashboard.
            """
        )
        alert.addButton(withTitle: Localization.string(zh: "知道了", en: "Got it"))
        alert.addButton(withTitle: Localization.string(zh: "打开官网", en: "Open the website"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(marketingURL)
        }
    }

    private static func isLocalDashboardHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// 在访达中定位本机守护记录文件，供孩子/家长查看或导出
    @objc private func exportAuditLog() {
        let url = AuditLog.auditFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            AuditLog.record("LOG_INITIALIZED 守护记录已创建")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 首次启动时，向使用本机的孩子展示一次知情披露
    private func presentFirstRunDisclosureIfNeeded() {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/disclosure-shown")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        showTransparencyInfo()
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: marker)
        AuditLog.record("DISCLOSURE_SHOWN 已向使用者展示知情披露")
    }

    @objc private func copyConfigPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(client.configFilePath, forType: .string)
    }

    @objc private func quitWithPassword() {
        guard let code = promptParentVerificationCode(
            title: Localization.string(zh: "退出 BigDaddy 客户端", en: "Exit BigDaddy Client"),
            message: Localization.string(
                zh: "请在家长控制端 Dashboard 生成安全退出验证码，输入后即可正常关闭客户端。",
                en: "Please generate a secure exit verification code on the parent dashboard, enter it to close the client."
            ),
            confirmTitle: Localization.string(zh: "安全退出", en: "Secure Exit")
        ) else { return }

        Task {
            let success = await client.verifyExitPassword(code)
            await MainActor.run {
                if success {
                    client.sendShutdownSync()
                    NSApp.terminate(nil)
                } else {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = Localization.string(zh: "认证失败", en: "Authentication Failed")
                    errorAlert.informativeText = Localization.string(
                        zh: "退出验证码不正确或已过期，请重新在家长端生成后重试。",
                        en: "The exit code is incorrect or expired. Please generate a new one on the parent dashboard and try again."
                    )
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            }
        }
    }

    /// 开机自动启动菜单项的响应。
    /// - 开启：只会扩大监控覆盖面、不构成绕过风险，任何状态下都直接落地、不设防护。
    /// - 关闭（已绑定）：敏感操作（下次登录起守护就起不来），走家长验证码流程，
    ///   见 disableLaunchAtLoginWithVerification。
    /// - 关闭（未绑定）：此时还没有家长账户可以签发/校验验证码，也没有任何守护在进行，
    ///   直接关闭即可；真正的兜底是"绑定成功时强制恢复自启"（enforceLaunchAtLoginOnBind），
    ///   所以孩子在绑定前关掉自启并不能形成持久绕过——家长一接管就会被重新打开。
    ///   这样也避免了"未绑定时弹验证码框、却随便输 6 位都能过"（verifyExitPassword 对
    ///   未绑定设备恒返回 true）那种自相矛盾的体验。
    @objc private func toggleLaunchAtLogin() {
        if LaunchAtLoginPreference.isEnabled {
            if client.config.bound {
                disableLaunchAtLoginWithVerification()
            } else {
                applyLaunchAtLogin(enabled: false, source: "local-unbound")
            }
        } else {
            applyLaunchAtLogin(enabled: true, source: "local")
        }
    }

    /// 落地一次自启开关变更：写偏好、安装/卸载 LaunchAgent、记审计、重建菜单，
    /// 并立即补发一次心跳把新状态推给后端（心跳 metadata 里带 launchAtLoginEnabled），
    /// 不必等下一次定时心跳，家长端近实时可见。
    private func applyLaunchAtLogin(enabled: Bool, source: String) {
        LaunchAtLoginPreference.isEnabled = enabled
        if enabled {
            LaunchAtLoginController.enable()
        } else {
            LaunchAtLoginController.disable()
        }
        AuditLog.record("LAUNCH_AT_LOGIN_TOGGLE state=\(enabled ? "ENABLED" : "DISABLED") source=\(source)")
        rebuildMenu()
        Task { await client.sendHeartbeat(event: .heartbeat) }
    }

    /// 设备绑定成功这一刻强制把开机自启恢复为开启：抵消孩子在"未绑定期间"可能已经
    /// 关掉自启、导致家长接管后下次重启守护起不来的情况。绑定即家长正式接管，
    /// 自启动必须回到默认开启；此后再要关闭，就必须走验证码流程了。
    private func enforceLaunchAtLoginOnBind() {
        let wasEnabled = LaunchAtLoginPreference.isEnabled
        LaunchAtLoginPreference.isEnabled = true
        LaunchAtLoginController.enable()
        if !wasEnabled {
            AuditLog.record("LAUNCH_AT_LOGIN_REENABLED_ON_BIND")
        }
    }

    /// 关闭"开机自动启动"会让守护从下次登录起失效，且不需要退出客户端本身——如果做成
    /// 自由开关，孩子关掉它再重启一次电脑就能悄悄绕过守护，与"安全退出"的验证强度
    /// 不一致。这里复用同一个后端验证码接口（verifyExitPassword / verify-exit）和同一套
    /// 6 位数字输入 UI，家长在 Dashboard 生成的验证码同时能用于"退出"和"关闭自启动"
    /// 两个敏感动作。仅在已绑定设备走此路径（未绑定见 toggleLaunchAtLogin 注释）。
    private func disableLaunchAtLoginWithVerification() {
        guard let code = promptParentVerificationCode(
            title: Localization.string(zh: "关闭开机自动启动", en: "Turn Off Start at Login"),
            message: Localization.string(
                zh: "请在家长控制端 Dashboard 生成安全退出验证码，输入后即可关闭开机自动启动。",
                en: "Please generate a secure exit verification code on the parent dashboard, enter it to turn off Start at Login."
            ),
            confirmTitle: Localization.string(zh: "确认关闭", en: "Turn Off")
        ) else { return }

        Task {
            let success = await client.verifyExitPassword(code)
            await MainActor.run {
                if success {
                    applyLaunchAtLogin(enabled: false, source: "local-verified")
                } else {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = Localization.string(zh: "认证失败", en: "Authentication Failed")
                    errorAlert.informativeText = Localization.string(
                        zh: "验证码不正确或已过期，请重新在家长端生成后重试。",
                        en: "The code is incorrect or expired. Please generate a new one on the parent dashboard and try again."
                    )
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            }
        }
    }

    /// "安全退出"与"关闭开机自动启动"共用的 6 位家长验证码输入弹窗（含倒计时、
    /// 自动跳格），返回用户输入的 6 位数字；用户点取消，或未输满 6 位时返回 nil
    /// （未输满会先提示"请输入完整的 6 位验证码"）。调用方自行决定拿到码之后怎么
    /// 校验、以及成功/失败分别做什么。
    private func promptParentVerificationCode(title: String, message: String, confirmTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message

        let accessory = self.createExitAccessoryView()
        alert.accessoryView = accessory

        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))

        // 初始化倒计时
        self.countdownSeconds = 300
        self.updateExitCountdownLabelText()

        // 启动倒计时 Timer。selector 形式 + .common 模式：由运行循环直接回调、
        // 不依赖主队列排空，无论弹窗从哪种上下文调起都照常走秒（机制详见
        // showDeviceBindCode 里的说明）。
        self.countdownTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1.0, target: self, selector: #selector(exitCountdownTick),
            userInfo: nil, repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.countdownTimer = timer

        // 打开弹窗即可直接输入，不用先点一下第一个格子才能开始打字。
        // 之前用 alert.window.initialFirstResponder 设置，但 NSAlert 展示时会自己
        // 决定初始 first responder（一般落在默认按钮上，便于回车直接触发），会覆盖
        // 这个设置，实测不生效。改成在 runModal() 即将进入的模态运行循环里异步抢一次
        // 焦点——主队列的 async 任务在 modal panel 模式下照常会被处理，这是让 NSAlert
        // accessory view 里的控件拿到初始焦点的通用做法。
        if let firstDigitField = self.exitDigitFields.first {
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(firstDigitField)
            }
        }

        // 运行 Alert Modal
        let response = alert.runModal()

        // Modal 结束，释放计时器
        self.countdownTimer?.invalidate()
        self.countdownTimer = nil

        guard response == .alertFirstButtonReturn else { return nil }

        let code = self.exitDigitFields.map { $0.stringValue }.joined()
        if code.count < 6 {
            let errorAlert = NSAlert()
            errorAlert.messageText = Localization.string(zh: "验证失败", en: "Verification Failed")
            errorAlert.informativeText = Localization.string(zh: "请输入完整的 6 位验证码。", en: "Please enter the complete 6-digit verification code.")
            errorAlert.addButton(withTitle: Localization.string(zh: "确认", en: "Confirm"))
            errorAlert.runModal()
            return nil
        }
        return code
    }

    private func createExitAccessoryView() -> NSView {
        // NSAlert 按 accessoryView 的 frame 预留空间。之前直接返回一个零 frame、
        // 纯 Auto Layout 的 NSStackView，弹窗按错误的高度排版，验证码输入框被
        // 正文/按钮遮住一部分。与其他弹窗一致：外层用带明确 frame 的 NSView 撑开。
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 16
        container.alignment = .centerX
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false

        parentView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: parentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: parentView.trailingAnchor)
        ])


        let digitsStack = NSStackView()
        digitsStack.orientation = .horizontal
        digitsStack.spacing = 8
        digitsStack.alignment = .centerY
        
        self.exitDigitFields.removeAll()
        self.exitDigitPreviousValues = Array(repeating: "", count: 6)

        for _ in 0..<6 {
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 1.0
            box.borderColor = NSColor.separatorColor
            box.cornerRadius = 6.0
            box.fillColor = NSColor.controlBackgroundColor
            box.wantsLayer = true
            
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 36).isActive = true
            box.heightAnchor.constraint(equalToConstant: 44).isActive = true
            
            let field = NSTextField()
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = false
            field.drawsBackground = false
            field.alignment = .center
            field.font = NSFont.boldSystemFont(ofSize: 22)
            field.textColor = NSColor.labelColor
            field.delegate = self

            field.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(field)

            // 之前用 centerX/centerY 定位：field 没有显式宽高，靠空字符串时几乎为零的
            // intrinsic size 撑开，实际可点击/渲染区域只有框正中一小条，导致"点不中"
            // 「输入的数字被遮挡」。改成四边撑满 contentView，整个方框都可点击，数字
            // 也稳定居中显示，不再依赖会随内容变化的 intrinsic size。
            if let contentView = box.contentView {
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    field.topAnchor.constraint(equalTo: contentView.topAnchor),
                    field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
                ])
            }

            digitsStack.addArrangedSubview(box)
            self.exitDigitFields.append(field)
        }
        
        let countdownField = NSTextField()
        countdownField.isEditable = false
        countdownField.isSelectable = false
        countdownField.isBordered = false
        countdownField.drawsBackground = false
        countdownField.alignment = .center
        countdownField.font = NSFont.systemFont(ofSize: 12)
        countdownField.textColor = NSColor.secondaryLabelColor
        self.exitCountdownLabel = countdownField
        
        container.addArrangedSubview(digitsStack)
        container.addArrangedSubview(countdownField)

        return parentView
    }

    /// 退出弹窗的每秒 tick（selector 形式，modal 期间照常触发）
    @objc private func exitCountdownTick() {
        if countdownSeconds > 0 {
            countdownSeconds -= 1
            updateExitCountdownLabelText()
        } else {
            self.countdownTimer?.invalidate()
            self.countdownTimer = nil
            exitCountdownLabel?.stringValue = Localization.string(
                zh: "验证码已超时失效，请关闭此窗口并重新获取",
                en: "Verification code expired. Please close this window and try again."
            )
            exitCountdownLabel?.textColor = NSColor.systemRed
        }
    }

    private func updateExitCountdownLabelText() {
        guard countdownSeconds > 0 else { return }
        let minutes = countdownSeconds / 60
        let seconds = countdownSeconds % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)
        exitCountdownLabel?.stringValue = Localization.string(
            zh: "验证码将在 \(timeString) 后失效",
            en: "Verification code will expire in \(timeString)"
        )
    }

    /// 只负责"往前打字"：合法数字就取用、跳到下一格；非数字字符一律当作无效按键
    /// 拒绝掉、还原成这格之前的值，绝不在这里做任何跳格/清空判断。
    ///
    /// 之前的版本靠"过滤后文本是否为空"来判断要不要跳回上一格，但这个信号有歧义：
    /// 本格已有数字（比如"3"）时，makeFirstResponder 会让整格文本被选中；这时哪怕
    /// 只是输入一个非数字字符（比如字母），选中内容也会被替换掉，过滤后同样是空——
    /// 于是被误判成"用户按了删除"，不但把这格清空，还连锁跳到上一格、重复消耗后续
    /// 按键，实际表现就是"打几个非数字字符，前面输的数字全没了"。真正的删除已经
    /// 完全交给下面的 doCommandBy: 处理（那里能拿到"这次按键就是退格"这个确切信号，
    /// 不需要靠猜），这里就不用再兼顾删除语义。
    func controlTextDidChange(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              let index = exitDigitFields.firstIndex(of: textField) else { return }

        let digitsOnly = textField.stringValue.filter { $0.isNumber }
        guard let lastDigit = digitsOnly.last else {
            // 非数字字符：不是合法输入，也不可能是删除（删除已经在 doCommandBy: 里
            // 整个接管，走不到这里）。原样恢复，等于无视这次无效按键，光标留在原格。
            textField.stringValue = index < exitDigitPreviousValues.count ? exitDigitPreviousValues[index] : ""
            return
        }
        let newValue = String(lastDigit)
        textField.stringValue = newValue
        if index < exitDigitPreviousValues.count { exitDigitPreviousValues[index] = newValue }
        if index < 5 {
            textField.window?.makeFirstResponder(exitDigitFields[index + 1])
        }
    }

    /// 退格键的删除/跳格逻辑完全在这里处理，不依赖 controlTextDidChange 事后猜测：
    /// 本格有数字就先清空本格（光标留在原地，标准验证码退格体验——不会一下跳穿
    /// 好几格）；本格已空则跳到上一格并清空它，从而实现"一次退格删一位"的连续删除。
    /// 返回 true 表示自己已处理，阻止 AppKit 再走一遍默认删除（避免重复触发
    /// controlTextDidChange，也让"删除"和"打字"两条路径完全不交叉）。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.deleteBackward(_:)),
              let field = control as? NSTextField,
              let index = exitDigitFields.firstIndex(of: field) else {
            return false
        }
        if !field.stringValue.isEmpty {
            field.stringValue = ""
            if index < exitDigitPreviousValues.count { exitDigitPreviousValues[index] = "" }
            return true
        }
        guard index > 0 else { return true }
        let previous = exitDigitFields[index - 1]
        previous.stringValue = ""
        if index - 1 < exitDigitPreviousValues.count { exitDigitPreviousValues[index - 1] = "" }
        field.window?.makeFirstResponder(previous)
        return true
    }

    /// C 的裸 signal() 处理器里不允许做内存分配、发起网络请求或创建 Swift Task
    /// （非 async-signal-safe），之前的实现在处理器里直接触发异步网络调用，有
    /// 死锁/崩溃风险；而且从未调用 exit()，一旦自定义处理器接管了默认终止行为，
    /// SIGTERM/SIGINT/SIGHUP 可能根本杀不死进程，只能靠 kill -9 兜底。
    /// 这里改用 DispatchSourceSignal：先用 SIG_IGN 屏蔽默认终止动作，再在正常
    /// GCD 队列上异步处理信号（可以安全地做网络上报），处理完成后显式 exit(0)。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                BigDaddyClient.sharedForceKillPing {
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func checkScreenRecordingPermission() -> Bool {
        client.hasScreenRecordingAccess()
    }

    /// 绑定自检里"浏览器网址"这些行的状态。
    ///
    /// 列的是**本机已安装的每一个受支持浏览器**，不是只看默认浏览器：自动化权限按
    /// "发起方 × 目标"逐对授权，孩子同时装着 Chrome / Arc / Brave / Vivaldi 是常态，
    /// 只查默认浏览器意味着另外三个要等孩子真的用到、被运行期的 onBrowserAutomationBlocked
    /// 逐个打断才浮出来。把日后四次零散打断换成绑定那一刻的一次集中确认，对家长和孩子
    /// 都更省事，家长也才第一次看清"这台机器上到底有几个浏览器要管"。
    ///
    /// 一律用 promptIfNeeded: false：这里只是渲染一张清单，不能同步阻塞去弹授权框。
    private func browserAutomationStates() -> [(bundleID: String, permission: BigDaddyClient.AutomationPermission)] {
        BigDaddyClient.installedSupportedBrowsers().map {
            ($0, BigDaddyClient.automationPermission(forBundleID: $0, promptIfNeeded: false))
        }
    }

    /// 上面那些浏览器里"用户还需要做点什么"的部分。
    ///
    /// targetNotRunning 不算：浏览器没在跑时既判定不了、也授权不了（系统授权框要求目标
    /// App 在运行），把它算成"待办"只会在自检里摆一个点了也没用的按钮。这些浏览器会在
    /// 孩子下次真正打开它们时由 onBrowserAutomationBlocked 接手。
    private func browserAutomationNeedingAttention() -> [String] {
        browserAutomationStates()
            .filter { $0.permission != .granted && $0.permission != .targetNotRunning }
            .map(\.bundleID)
    }

    private func createPermissionCheckerView(hasAccessibility: Bool) -> NSView {
        // 创建具有明确 frame 的普通 NSView 作为最外层容器，撑开 NSAlert 的 accessoryView 空间。
        // 高度最后按内容实测（见函数末尾）：浏览器行数由本机装了几个浏览器决定，从 0 到 5
        // 都有可能，写死高度会把多出来的行裁掉。
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 16
        container.alignment = .leading
        container.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        container.translatesAutoresizingMaskIntoConstraints = false
        
        parentView.addSubview(container)
        
        // 用 Auto Layout 让 container 贴满 parentView
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: parentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: parentView.trailingAnchor)
        ])
        
        // 辅助功能行
        let accRow = createPermissionRow(
            title: Localization.string(zh: "辅助功能权限", en: "Accessibility Permission"),
            description: Localization.string(
                zh: "用于读取前台活动窗口标题，生成使用摘要（家庭已知情）",
                en: "Read active window titles to build usage summaries (with the family's knowledge)"
            ),
            status: hasAccessibility ? .granted : .needsAction,
            action: #selector(openAccessibilitySettings)
        )
        container.addArrangedSubview(accRow)

        // 浏览器网址读取（Apple Events 自动化）：与辅助功能、屏幕录制是三种彼此独立的
        // TCC 权限，缺了它家长端只有页面标题、没有链接。每个已安装的受支持浏览器一行——
        // 这是一份"逐对授权"的清单，合并成一行就说不清到底是哪个浏览器还没授权。
        //
        // 但行数必须封顶：Safari 在每台 Mac 上都存在，再叠上 Chrome 的 canary/beta/dev、
        // Edge、Brave、Vivaldi、Opera、Arc……装得多的机器能凑出十几行，而 NSAlert 的
        // accessoryView 不会滚动，太高会把下面的按钮顶出屏幕。排序上让"待办"排在最前，
        // 保证被截掉的永远是已授权/无法判定这类不需要动手的行。
        let allStates = browserAutomationStates()
        let ranked = allStates.enumerated().sorted { lhs, rhs in
            let rank: (BigDaddyClient.AutomationPermission) -> Int = {
                switch $0 {
                case .granted: return 2
                case .targetNotRunning: return 1
                default: return 0    // 需要用户处理的排最前
                }
            }
            let (lRank, rRank) = (rank(lhs.element.permission), rank(rhs.element.permission))
            // 同档内保持 installedSupportedBrowsers 定下的顺序（运行中的在前）
            return lRank == rRank ? lhs.offset < rhs.offset : lRank < rRank
        }.map(\.element)
        for state in ranked.prefix(Self.maxBrowserPermissionRows) {
            let browserName = Self.browserDisplayName(forBundleID: state.bundleID)
            // 没在运行的浏览器判定不了，也授权不了：如实标成"未运行"而不是 ❌。
            // 摆一个点了没反应的"去授权"按钮，比不摆更伤信任。
            let status: PermissionRowStatus
            switch state.permission {
            case .granted: status = .granted
            case .targetNotRunning: status = .indeterminate
            default: status = .needsAction
            }
            let row = createPermissionRow(
                title: Localization.string(zh: "浏览器网址读取 · \(browserName)",
                                           en: "Browser URL Access · \(browserName)"),
                description: status == .indeterminate
                    ? Localization.string(
                        zh: "\(browserName) 当前未运行，无法确认；孩子下次打开它时会自动提示授权",
                        en: "\(browserName) isn't running, so this can't be checked yet — BigDaddy will prompt when it's next opened"
                      )
                    : Localization.string(
                        zh: "读取 \(browserName) 当前网址，家长端才能看到可点击的访问记录",
                        en: "Read the current address in \(browserName) so the dashboard can show clickable links"
                      ),
                status: status,
                action: #selector(authorizeAllBrowserAutomation)
            )
            container.addArrangedSubview(row)
        }

        // 被截掉的那些如实交代一句，而不是让家长以为清单就这么长
        let hidden = allStates.count - min(allStates.count, Self.maxBrowserPermissionRows)
        if hidden > 0 {
            let more = NSTextField(labelWithString: Localization.string(
                zh: "另有 \(hidden) 个已授权/未运行的浏览器未列出",
                en: "\(hidden) more browser(s) already authorized or not running"
            ))
            more.font = NSFont.systemFont(ofSize: 11)
            more.textColor = NSColor.secondaryLabelColor
            container.addArrangedSubview(more)
        }

        // 强制先跑一次真实的 Auto Layout：换行文本框（descLabel）的 intrinsicContentSize
        // 在没有真正参与过布局时永远按"单行"计算高度（AppKit 不知道它最终会被约束到多宽，
        // 因而算不出要换几行）——所以"冷"读 fittingSize 会把每一处两行说明都按一行的
        // 高度计入，行数一多，缺口累计起来就是家长截图里那种下一行文字压住上一行的重叠。
        // 跑一次真实布局后，每个 descLabel 已经有了实际解出来的宽度，intrinsicContentSize
        // 才会算出正确的换行高度，fittingSize 也就跟着准了。
        container.layoutSubtreeIfNeeded()
        // 行数是运行期才知道的，按实际内容定高，避免多出来的浏览器行被裁掉
        parentView.frame = NSRect(x: 0, y: 0, width: 400, height: container.fittingSize.height)
        return parentView
    }

    /// 绑定自检里"去授权"按钮：把所有待办浏览器一次性交给运行期同一套引导逻辑。
    ///
    /// 不只处理被点的那一行：授权引导本来就是逐个浏览器串行走完的，让家长为了同一件事
    /// 在同一张清单上点三次，纯属把实现细节转嫁给用户。
    @objc private func authorizeAllBrowserAutomation() {
        let pending = browserAutomationNeedingAttention()
        guard !pending.isEmpty else { return }
        automationDeniedBundleIDs.formUnion(pending)
        promptAutomationPermission()
    }

    /// 权限行的三态。indeterminate 是"查不出来"（浏览器没运行），必须和"没授权"分开——
    /// 前者用户此刻做不了任何事，后者才是一条待办。
    private enum PermissionRowStatus {
        case granted
        case needsAction
        case indeterminate
    }

    private func createPermissionRow(title: String, description: String,
                                     status: PermissionRowStatus, action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 380).isActive = true

        // 1. 状态图标
        let symbol: String
        switch status {
        case .granted: symbol = "✅"
        case .needsAction: symbol = "❌"
        case .indeterminate: symbol = "⏸"
        }
        let statusLabel = NSTextField(labelWithString: symbol)
        statusLabel.font = NSFont.systemFont(ofSize: 18)
        row.addArrangedSubview(statusLabel)

        // 2. 文本介绍
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.textColor = NSColor.labelColor
        textStack.addArrangedSubview(titleLabel)
        
        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = NSColor.secondaryLabelColor
        descLabel.cell?.wraps = true
        descLabel.cell?.isScrollable = false
        textStack.addArrangedSubview(descLabel)
        
        row.addArrangedSubview(textStack)
        
        // 3. 操作按钮 (利用 textStack 自动拉伸，将按钮顶到最右侧)
        let button = NSButton()
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 90).isActive = true
        
        switch status {
        case .granted:
            button.title = Localization.string(zh: "已授权", en: "Authorized")
            button.isEnabled = false
        case .indeterminate:
            button.title = Localization.string(zh: "未运行", en: "Not running")
            button.isEnabled = false
        case .needsAction:
            button.title = Localization.string(zh: "去授权", en: "Authorize")
            button.target = self
            button.action = action
        }
        row.addArrangedSubview(button)
        
        // 约束优先级与拉伸对齐
        row.distribution = .fill
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        
        return row
    }

    /// 绑定前的权限自检。两项权限的"必要程度"不同，处理方式也不同：
    /// - 辅助功能：缺了连窗口标题都拿不到，守护基本失效，**阻断绑定**；
    /// - 浏览器网址读取（自动化）：缺了只是家长端看不到链接、仍有标题，属于降级而非
    ///   失效，所以只在弹窗里如实展示 ❌ 和"去授权"按钮，**不阻断绑定**——为一个可降级
    ///   的能力挡住整个绑定流程，代价和收益完全不成比例。
    private func checkAndRequestPermissions() -> Bool {
        let hasAccessibility = AXIsProcessTrustedWithOptions(nil)
        let automationNeedsAttention = !browserAutomationNeedingAttention().isEmpty

        if hasAccessibility && !automationNeedsAttention {
            return true
        }

        let alert = NSAlert()
        alert.messageText = hasAccessibility
            ? Localization.string(zh: "还有一项权限建议开启", en: "One More Permission Recommended")
            : Localization.string(zh: "需要系统辅助功能权限", en: "Accessibility Permission Required")
        alert.informativeText = hasAccessibility
            ? Localization.string(
                zh: "辅助功能已就绪。还差浏览器网址读取权限——没有它，家长端只能看到网页标题、看不到可点击的网址。可以点击右侧「去授权」现在开启，也可以先继续绑定、之后从菜单栏「关于 BigDaddy…」里补上。",
                en: "Accessibility is ready. Browser URL access is still missing — without it the dashboard shows page titles but no clickable links. Grant it now with 'Authorize', or continue binding and enable it later from “About BigDaddy…”."
            )
            : Localization.string(
                zh: "为了能够正常守护您的孩子，BigDaddy 客户端需要辅助功能权限支持。请点击右侧的“去授权”按钮，在弹出的系统设置中勾选允许 `BigDaddy`，然后点击“我已开启，继续绑定”。",
                en: "To protect your child, BigDaddy needs Accessibility permission. Click 'Authorize' to grant access in System Settings, then click 'I've enabled, continue'."
            )

        let accessory = createPermissionCheckerView(hasAccessibility: hasAccessibility)
        alert.accessoryView = accessory

        alert.addButton(withTitle: Localization.string(zh: "我已开启，继续绑定", en: "I've enabled, continue"))
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // 家长配置好后点击“继续”，递归刷新自检状态。
            // 辅助功能已就绪时不再递归——否则用户选择"网址权限以后再说"就会陷入
            // 同一个弹窗反复出现、点不掉的死循环；"不阻断"靠的是这颗"继续"按钮放行，
            // 而不是把「取消」也偷偷当成继续。
            return hasAccessibility ? true : checkAndRequestPermissions()
        }

        // 取消就是取消：即便只差可降级的网址权限，用户点「取消」也应中止绑定流程，
        // 想跳过网址权限继续绑定的话，上面的「继续」按钮本来就是干这个的。
        return false
    }

    private func restartApplication() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        try? process.run()
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        // 先发带 prompt 的查询再开设置页，顺序不能反。
        //
        // 这一步不只是"弹个框"：**只有真正请求过一次，BigDaddy 才会出现在
        // 「隐私与安全性 → 辅助功能」的名单里**。macOS 的这个名单只列出请求过该权限的
        // App，从没请求过的应用连一行灰色条目都不会有。所以如果跳过它直接开设置页，
        // 家长看到的是一个根本找不到 BigDaddy 的列表——"按提示去设置里勾上"这条路
        // 在那之前是死的（自动化权限那边踩过同一个坑，见 showAutomationPromptUnavailable）。
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 菜单/「关于」窗口里"辅助功能未授权 · 点此修复"的响应。
    ///
    /// 已经授权时不重复打扰，直接确认一句就好——权限可能在家长点开菜单到点下这一项
    /// 之间刚好被打开（菜单项的文字是上一次 rebuildMenu 时算的，未必是此刻的真相）。
    ///
    /// 授权成功后**不需要重启**客户端：AXIsProcessTrusted 会实时反映最新状态，
    /// 下一次心跳就能带上窗口标题和 Firefox 的网址——这点和屏幕录制不同（那个受
    /// 进程级缓存影响，必须重启，所以那条路才有"已授权？重启客户端"的第二步）。
    @objc private func promptAccessibilityPermission() {
        guard !AXIsProcessTrustedWithOptions(nil) else {
            let done = NSAlert()
            applyShieldIcon(to: done)
            done.messageText = Localization.string(zh: "辅助功能已授权", en: "Accessibility is on")
            done.informativeText = Localization.string(
                zh: "本机已经允许 BigDaddy 使用辅助功能，窗口标题和网址记录都能正常采集。",
                en: "This Mac already allows BigDaddy to use Accessibility; window titles and addresses are being recorded normally."
            )
            done.runModal()
            rebuildMenu()
            return
        }

        let alert = NSAlert()
        applyShieldIcon(to: alert)
        alert.messageText = Localization.string(zh: "需要辅助功能权限", en: "Accessibility permission needed")
        alert.informativeText = Localization.string(
            zh: "缺少这项权限时，家长端看到的记录会没有窗口标题，Firefox 一类浏览器也读不到网址。\n\n点「去授权」后，系统会弹出询问并打开设置页面；在「隐私与安全性 → 辅助功能」的名单里把 BigDaddy 打开即可，开启后立即生效，不需要重启。",
            en: "Without it, the parent dashboard shows records with no window title, and browsers like Firefox report no address.\n\nChoose “Authorize” — macOS will ask and open the settings page. Switch BigDaddy on under Privacy & Security → Accessibility. It takes effect immediately; no restart needed."
        )
        alert.addButton(withTitle: Localization.string(zh: "去授权", en: "Authorize"))
        alert.addButton(withTitle: Localization.string(zh: "以后再说", en: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openAccessibilitySettings()
        startAccessibilityGrantWatch()
    }

    /// 家长去系统设置期间盯着权限状态，一旦打开就把菜单里那条警示摘掉。
    ///
    /// 需要主动盯：辅助功能的授权发生在**另一个进程**（系统设置）里，本进程收不到任何
    /// 通知；不盯的话，家长明明已经勾上了，菜单里那条"⚠️ 未授权"还挂着，看起来像没生效。
    /// 每 2 秒查一次、最多 2 分钟——AXIsProcessTrustedWithOptions(nil) 不弹窗、不打扰。
    private func startAccessibilityGrantWatch() {
        accessibilityWatchTimer?.invalidate()
        var elapsed: TimeInterval = 0
        accessibilityWatchTimer = scheduleCommonModeTimer(interval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                elapsed += 2
                if AXIsProcessTrustedWithOptions(nil) || elapsed >= 120 {
                    timer.invalidate()
                    self.accessibilityWatchTimer = nil
                    self.rebuildMenu()
                    // 菜单栏图标同样由这个权限驱动（见 updateStatusItemAppearance），
                    // 授权到手后要把警示态一起摘掉，否则家长开完权限还盯着一个 ⚠️。
                    self.updateStatusItemAppearance()
                }
            }
        }
    }
    
    /// "前往系统设置授权"：进入两步流程的第 2 步，并且**把「关于」窗口留在原地**。
    ///
    /// 顺序很关键，两件事都要做对：
    ///
    /// 1. 先把 awaitingScreenRecordingGrant 置位、再重建「关于」窗口。aboutActionTapped
    ///    会在调用本方法之前先关掉窗口（那是它的通用行为，别的按钮都指望着这一点），
    ///    所以这里主动重建一次，家长从系统设置切回来时窗口还在，而且已经变成"第 2 步：
    ///    立即重启生效"的样子。这正是原来那个"点完按钮窗口就没了、第二步入口消失"的
    ///    问题的修复点。
    /// 2. 系统设置必须**最后**打开。showAboutWindow 结尾有 NSApp.activate +
    ///    makeKeyAndOrderFront，如果先开设置再重建窗口，我们会把焦点从系统设置抢回来，
    ///    家长得自己再切回去——反而更烦。
    @objc private func openScreenRecordingSettings() {
        awaitingScreenRecordingGrant = true
        CGRequestScreenCaptureAccess()
        // 菜单栏一级菜单里那条"已授权？点此重启生效"的提醒也依赖这个状态
        rebuildMenu()
        showAboutWindow()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 网站访问限制此刻需不需要家长动手，以及要动哪一手。
    ///
    /// 三种情况收进一个枚举，是因为同一个判断要出现在四个地方（菜单栏图标、菜单项、
    /// "关于"窗口、引导弹窗）。此前只有"待批准"一种被处理，另外两种——激活失败、
    /// 以及扩展被人从系统设置里关掉——在客户端这边完全静默：图标不变、菜单里没有入口、
    /// "关于"窗口里也没有，家长唯一可能察觉的途径是自己打开仪表盘看到一行红字。
    /// 而这两种恰恰是"配置了但实际不生效"，跟屏幕录制缺权限属于同一类问题，理应用
    /// 同一套视觉语言提醒。
    enum WebFilterAttention: Equatable {
        case none
        /// 系统弹过"扩展已被阻止"，家长还没去批准
        case awaitingApproval
        /// 批准过、也配置好了，但系统里的过滤开关被人关掉了
        case disabledExternally
        /// 激活或配置失败，带上系统给的原因
        case failed(String)
    }

    private var webFilterAttention: WebFilterAttention {
        guard client.config.bound else { return .none }
        switch webFilterController.state {
        case .awaitingUserApproval:
            return .awaitingApproval
        case .failed(let message):
            return .failed(message)
        case .unavailable:
            // 这台机器上压根没装出扩展（打包/安装问题），家长去系统设置里也找不到
            // 任何可开的东西，指过去只会让他白跑一趟。仪表盘上仍会显示"系统扩展不可用"。
            return .none
        case .activationRequested, .approved, .configurationEnabled, .restartRequired:
            return webFilterController.isSystemFilterDisabledExternally ? .disabledExternally : .none
        }
    }

    private func webFilterMenuTitle(for attention: WebFilterAttention) -> String? {
        switch attention {
        case .none:
            return nil
        case .awaitingApproval:
            return Localization.string(
                zh: "⚠️ 授权网站访问限制…",
                en: "⚠️ Authorize Website Access Restrictions…"
            )
        case .disabledExternally:
            return Localization.string(
                zh: "⚠️ 网站访问限制已被关闭 · 点此恢复…",
                en: "⚠️ Website Restrictions Turned Off — Restore…"
            )
        case .failed:
            return Localization.string(
                zh: "⚠️ 网站访问限制启用失败 · 查看…",
                en: "⚠️ Website Restrictions Failed — Details…"
            )
        }
    }

    /// 进入"待批准"时主动弹一次，而不是干等家长注意到菜单栏图标变了颜色。
    ///
    /// BigDaddy 是 LSUIElement：没有 Dock 图标、没有窗口。系统那条"系统扩展已被阻止"
    /// 的通知转瞬即逝，而绑定往往是家长在**自己**电脑上完成的（/start 里"绑定"这一步
    /// 标的就是"在你自己的设备上"），激活请求却发生在孩子那台机器上——真正看到系统
    /// 提示的那个人，多半根本不知道那是什么。主动弹窗是这条链路上唯一不依赖"恰好有人
    /// 盯着菜单栏"的提醒。
    ///
    /// 每次激活请求只弹一次：家长点了"取消"之后，菜单项和菜单栏的 ⚠️ 仍然常驻，
    /// 不至于既骚扰又失联。
    private func promptWebFilterApprovalIfNeeded() {
        guard case .awaitingApproval = webFilterAttention else {
            webFilterApprovalPromptShown = false
            return
        }
        guard !webFilterApprovalPromptShown else { return }
        webFilterApprovalPromptShown = true
        openWebFilterAuthorization()
    }

    @objc private func openWebFilterAuthorization() {
        let attention = webFilterAttention
        guard attention != .none else { return }

        let alert = NSAlert()
        applyShieldIcon(to: alert)
        alert.alertStyle = .warning

        // 只有"还没批准"落到函数末尾共用的两按钮弹窗；"被人关掉了"和"启用失败"
        // 都有 App 自己能触发的修复动作，各自三个按钮、各自 runModal，处理完直接
        // return，不再往下走。
        switch attention {
        case .none:
            return
        case .awaitingApproval:
            alert.messageText = Localization.string(
                zh: "需要批准网站访问限制",
                en: "Website Access Restrictions Need Approval"
            )
            alert.informativeText = Localization.string(
                zh: "点「继续」后，系统会打开“登录项与扩展”里的“网络扩展”。在列表里找到 BigDaddy.app，把它右边的开关打开；这是 macOS 为网络过滤设置的安全确认，批准后会自动继续同步策略。\n\n如果没有直接跳到“网络扩展”：在“登录项与扩展”页面拉到底部的“扩展”，找到“网络扩展”这一行，点它最右边的小图标（不同 macOS 版本样子不太一样，有的是三个点，有的是一个圆圈里带个 i）。",
                en: "Continue to open Network Extensions under Login Items & Extensions. Find BigDaddy.app in the list and turn on its switch. macOS requires this security confirmation for network filtering; policy synchronization resumes automatically after approval.\n\nIf it doesn't jump straight to Network Extensions: scroll to Extensions at the bottom of Login Items & Extensions, find the Network Extensions row, and click the small icon at its right end (its look varies by macOS version — sometimes three dots, sometimes a circled i)."
            )
        case .disabledExternally:
            alert.messageText = Localization.string(
                zh: "网站访问限制已被关闭",
                en: "Website Access Restrictions Are Turned Off"
            )
            alert.informativeText = Localization.string(
                zh: "BigDaddy 的网络扩展被关掉了，家长设置的域名当前一个都没有拦截。\n\n多数情况下点「重新开启」就能直接恢复，不用去系统设置。如果点完仍然显示已关闭，再走「打开系统设置」：在“登录项与扩展”页面拉到底部的“扩展”，找到“网络扩展”这一行，点它最右边的小图标（不同 macOS 版本样子不太一样，有的是三个点，有的是一个圆圈里带个 i），把 BigDaddy.app 的开关打开。",
                en: "BigDaddy's network extension was turned off, so none of the configured domains are being blocked right now.\n\nIn most cases \"Turn It Back On\" restores it directly — no trip to System Settings needed. If it still shows as off afterwards, use \"Open System Settings\": scroll to Extensions at the bottom of Login Items & Extensions, find the Network Extensions row, click the small icon at its right end (its look varies by macOS version — sometimes three dots, sometimes a circled i), and switch BigDaddy.app on."
            )
            // 这一种给三颗按钮：先给最省事的那条（直接重开），系统设置退居备选。
            alert.addButton(withTitle: Localization.string(zh: "重新开启", en: "Turn It Back On"))
            alert.addButton(withTitle: Localization.string(zh: "打开系统设置", en: "Open System Settings"))
            alert.addButton(withTitle: Localization.string(zh: "稍后再说", en: "Later"))
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                webFilterController.repairSystemFilterNow()
            case .alertSecondButtonReturn:
                openNetworkExtensionSettings()
            default:
                break
            }
            return
        case .failed(let message):
            alert.messageText = Localization.string(
                zh: "网站访问限制启用失败",
                en: "Website Access Restrictions Failed to Start"
            )
            // 启用这项功能实际要过两道系统关卡：「登录项与扩展→网络扩展」里的开关（一次性，
            // 批准过就不会再问），和每次真正保存过滤配置时系统弹出的"允许网络过滤"确认框。
            // 孩子在任一处点了"不允许"/"取消"都会落到这个分支，但家长光看错误原因分不清是
            // 哪一处——所以文案把两处都点名，并且明确告诉家长点「重试」之后要盯着屏幕看
            // 有没有新弹窗，而不是无差别地建议重启。
            alert.informativeText = Localization.string(
                zh: "系统给出的原因：\(message)\n\n启用网站访问限制需要两处系统授权都通过：「登录项与扩展→网络扩展」里 BigDaddy.app 的开关，以及点「重试」时系统会弹出的“允许网络过滤”确认框——这次没能生效，多半是其中一处被跳过或点了“不允许”。\n\n点「重试」后请留意 Mac 屏幕上新弹出的系统确认框，选择“允许”。如果没有新弹窗出现，说明卡在开关那一步：先点「打开系统设置」，在“网络扩展”里确认 BigDaddy.app 的开关是打开的，再回来点一次「重试」。",
                en: "The system reported: \(message)\n\nTurning on website restrictions needs two separate system approvals: BigDaddy.app's switch under Network Extensions in Login Items & Extensions, and the \"Allow filtering network content\" confirmation macOS shows when saving the filter. This attempt likely missed or declined one of them.\n\nClick Retry and watch this Mac's screen for a new system confirmation — choose Allow. If no new prompt appears, the switch is the one that's off: use Open System Settings to confirm BigDaddy.app is on under Network Extensions, then click Retry again."
            )
            // 「重试」放第一位、且真的调用 repairSystemFilterNow() 重新走一遍
            // enableContentFilter()：这是家长在孩子 Mac 前唯一需要做的事——不管刚才是
            // 开关没打开还是过滤确认框被拒，重新触发一次保存都会让系统把该问的再问一遍，
            // 不需要重启整台 Mac。系统设置退居备选，给"开关到底有没有打开"存疑时用。
            alert.addButton(withTitle: Localization.string(zh: "重试", en: "Retry"))
            alert.addButton(withTitle: Localization.string(zh: "打开系统设置", en: "Open System Settings"))
            alert.addButton(withTitle: Localization.string(zh: "稍后再说", en: "Later"))
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                webFilterController.repairSystemFilterNow()
            case .alertSecondButtonReturn:
                openNetworkExtensionSettings()
            default:
                break
            }
            return
        }

        alert.addButton(withTitle: Localization.string(zh: "继续", en: "Continue"))
        alert.addButton(withTitle: Localization.string(zh: "稍后再说", en: "Later"))
        // LSUIElement 的进程不会自动成为前台应用，不抢一次焦点的话这个弹窗会开在
        // 所有窗口后面——家长看到的仍然是"什么都没发生"。
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openNetworkExtensionSettings()
    }

    /// 直接落到「网络扩展」那张详情表单，而不是「登录项与扩展」整页。
    ///
    /// 整页打开的话，家长还得自己滚到底部、在“扩展”里找到“网络扩展”、点它右边那个
    /// 详情图标（这个图标的样子本身也随 macOS 版本变过，实测 macOS 27 上是个圆圈
    /// 带 i，不是老版本常说的“显示细节”/三个点），三步之后才是那个开关——而这正是
    /// 最容易走丢的三步。
    /// com.apple.ExtensionsPreferences 是「登录项与扩展」面板自己声明的 url_alias
    /// （见 /System/Library/ExtensionKit/Extensions/LoginItems.appex 的 Info.plist），
    /// 带上 extensionPointIdentifier 可以直接把对应那张表单弹出来。
    ///
    /// 不需要退路：参数万一被这个 macOS 版本忽略，落点也就是「登录项与扩展」整页，
    /// 跟改动之前完全一样，家长最多多点两下。弹窗文案里那段"如果没有直接跳到…"
    /// 就是为这种情况写的。
    private func openNetworkExtensionSettings() {
        let deepLink = "x-apple.systempreferences:com.apple.ExtensionsPreferences"
            + "?extensionPointIdentifier=com.apple.system_extension.network_extension"
        if let url = URL(string: deepLink) {
            NSWorkspace.shared.open(url)
        }
    }

    /// "允许读取浏览器网址"按钮：先对每个被拒的浏览器重新查一次当前状态。
    ///
    /// 为什么要重查而不是直接开系统设置：用户可能已经在别处授权好了（自动化权限改完
    /// 立即生效，不像屏幕录制那样有进程级缓存），这时该告诉他"已经好了"，而不是再把
    /// 他推去设置里找一个已经勾上的开关——屏幕录制那边只能摆两个按钮让用户自己猜，
    /// 是因为那个状态在本进程内查不准；这里查得准，就不该让用户猜。
    ///
    /// 仍是 notDetermined 的，直接弹系统原生授权框（一次点击就能解决）；确实是 denied
    /// 的，才打开系统设置的自动化面板并说明要勾哪一项。
    @objc private func promptAutomationPermission() {
        let targets = Array(automationDeniedBundleIDs)
        guard !targets.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 必须把"有记录、被拒"和"根本没有记录"分开：系统设置的自动化面板只列出
            // **已经产生过 TCC 记录**的 App，没有记录的话那个面板里连 BigDaddy 这一栏
            // 都不存在，把用户送过去只会让他对着一个空列表发懵。
            var denied: [String] = []      // -1743：有记录、用户拒过 → 去设置里勾
            var noRecord: [String] = []    // -1744/其他：没有记录 → 去设置没用
            // 探测顺手读到的真实网址，用来把"已生效"从一句断言变成一个可核对的事实。
            // 这里只留 bundle id，浏览器显示名回到主线程再解析（NSWorkspace 查询是
            // 主线程隔离的）。
            var evidence: [(bundleID: String, url: String)] = []
            for bundleID in targets {
                // 用真实 Apple Event 探测：这是唯一能可靠让系统弹出授权询问、并在 TCC
                // 里落下记录的方式（见 probeAutomation 的注释）。先前这里只调
                // AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)，在它不弹
                // 询问的情况下既建不出记录，又被判成"被拒"，用户就被送去一个根本没有
                // BigDaddy 条目的自动化面板。
                guard let probe = self?.client.probeAutomation(bundleID: bundleID) else { continue }
                switch probe.permission {
                case .granted:
                    if let url = probe.url {
                        evidence.append((bundleID, url))
                    }
                case .targetNotRunning:
                    // 浏览器没开就无法判定，也无法授权；不算失败，等它下次开起来再说
                    continue
                case .denied:
                    denied.append(bundleID)
                case .notDetermined, .unknown:
                    noRecord.append(bundleID)
                }
            }
            // 跨线程边界前定格成不可变副本：直接捕获上面那三个 var，编译器无法证明
            // "派发之后不会再被改"，Swift 6 下会直接判成错误（旧版编译器只给警告）。
            let (finalDenied, finalNoRecord, finalEvidence) = (denied, noRecord, evidence)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.automationDeniedBundleIDs = Set(finalDenied + finalNoRecord)
                self.rebuildMenu()
                if finalDenied.isEmpty && finalNoRecord.isEmpty {
                    self.automationNoticeShownAt.removeAll()
                    self.showAutomationGranted(evidence: finalEvidence)
                    return
                }
                if !finalDenied.isEmpty {
                    self.showAutomationSettingsGuidance(bundleIDs: finalDenied)
                } else {
                    self.showAutomationPromptUnavailable(bundleIDs: finalNoRecord)
                }
            }
        }
    }

    /// 授权走通后的确认框。
    ///
    /// 带上刚刚**真实读到的网址**，而不是只说一句"已生效"：这是用户能当场核对的证据，
    /// 也是最强的成功信号——他看到的就是自己浏览器里那一页。顺带堵死一类误判：读不出
    /// 任何真实网址时（浏览器没窗口、或探测本身判错了），文案就退回成不打包票的说法，
    /// 绝不拿一句"已生效"糊过去。此前那版无条件宣称成功，配合探测的漏判，出现过
    /// "客户端说已生效、家长端一直显示未授权"的自相矛盾。
    private func showAutomationGranted(evidence: [(bundleID: String, url: String)]) {
        let alert = NSAlert()
        applyShieldIcon(to: alert)
        if let sample = evidence.first {
            let browser = Self.browserDisplayName(forBundleID: sample.bundleID)
            alert.messageText = Localization.string(zh: "网址记录已生效", en: "Website Logging Enabled")
            // 长网址会把弹窗撑得很宽，截断到能认出是哪一页即可
            let shown = sample.url.count > 80 ? String(sample.url.prefix(80)) + "…" : sample.url
            alert.informativeText = Localization.string(
                zh: "刚刚从 \(browser) 读到的网址是：\n\(shown)\n\n下一次上报起，家长端的访问记录就会带上可点击的链接，不需要重启。",
                en: "Just read this address from \(browser):\n\(shown)\n\nFrom the next report on, the parent dashboard will show clickable links — no restart needed."
            )
        } else {
            alert.messageText = Localization.string(zh: "授权已通过", en: "Authorization Granted")
            alert.informativeText = Localization.string(
                zh: "系统已允许 BigDaddy 读取浏览器网址，但此刻浏览器没有打开任何网页，所以还没读到具体地址。孩子下次浏览网页时，家长端就会开始出现可点击的链接。",
                en: "macOS now allows BigDaddy to read browser addresses, but no page is open right now, so there was nothing to read yet. Clickable links will start appearing once your child browses again."
            )
        }
        alert.runModal()
    }

    /// 当前运行的是不是一个正经的 .app（带 Info.plist 和用途说明字符串）。
    ///
    /// `swift run` / Xcode 直接运行产出的是裸 Mach-O：没有 Info.plist，也就没有
    /// NSAppleEventsUsageDescription。macOS 对此的处理是**拒绝弹出自动化授权框、直接
    /// 以 -1743 回绝、且不创建任何 TCC 记录**——于是系统设置的自动化面板里永远不会
    /// 出现 BigDaddy，这个权限在开发构建下无论如何都授不成。这不是代码问题，但如果
    /// 不明说，开发和测试时会反复撞上同一堵墙还以为是功能坏了。
    private var canRequestAutomationConsent: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") != nil
    }

    /// 系统没有为这些浏览器留下任何 TCC 记录 —— 去系统设置是没有意义的，
    /// 得说清楚真正该做什么。
    private func showAutomationPromptUnavailable(bundleIDs: [String]) {
        let names = bundleIDs.map { Self.browserDisplayName(forBundleID: $0) }.joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "系统没有弹出授权询问", en: "macOS Didn't Show the Prompt")
        alert.informativeText = canRequestAutomationConsent
            ? Localization.string(
                zh: "系统这次没有弹出「允许 BigDaddy 控制 \(names)」的询问，因此「隐私与安全性 → 自动化」里也还看不到 BigDaddy——那个列表只会列出已经询问过的 App。请确认 \(names) 正在运行、窗口没有全部关闭，然后再点一次本按钮。",
                en: "macOS didn't show the “allow BigDaddy to control \(names)” prompt, so BigDaddy won't appear under Privacy & Security → Automation yet — that list only shows apps that have already been asked. Make sure \(names) is running with at least one window open, then tap this button again."
            )
            : Localization.string(
                zh: "当前运行的是开发构建（未打包成 .app，缺少 Info.plist 中的用途说明），macOS 在这种情况下不会弹出自动化授权询问，也不会在「隐私与安全性 → 自动化」里创建 BigDaddy 条目。请改用打包并签名后的正式版本再试。",
                en: "This is a development build (a bare binary without the Info.plist usage description). macOS never shows the automation prompt for it, and won't create a BigDaddy entry under Privacy & Security → Automation. Use a packaged, signed build instead."
            )
        applyShieldIcon(to: alert)
        alert.runModal()
    }

    /// 用户此前点过"不允许"，系统不会再弹框，只能引导去系统设置手动勾选。
    /// 文案里点名具体浏览器：那个面板下是「BigDaddy」一栏里列着一串目标应用的勾选框，
    /// 不说清楚要勾哪个，用户很容易只勾了一个就以为设置完了。
    ///
    /// 但"去设置里勾"这条路本身也会卡死：那个面板不提供移除条目，而开关在客户端签名
    /// 身份变过、或记录已陈旧时扳不动（实测过），家长点半天没反应又无处可退。所以并排
    /// 给一条"重置后重新询问"——把这条本来只有命令行才走得通的退路做成一颗按钮。
    private func showAutomationSettingsGuidance(bundleIDs: [String]) {
        let names = bundleIDs.map { Self.browserDisplayName(forBundleID: $0) }.joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "需要在系统设置里手动开启", en: "Enable It in System Settings")
        alert.informativeText = Localization.string(
            zh: "系统记录了此前的「不允许」，不会再自动询问。请在打开的「隐私与安全性 → 自动化」里找到 BigDaddy，勾选它下面的 \(names)。勾选后立即生效，不需要重启。\n\n如果那里的开关点了没反应、或者根本找不到 BigDaddy，请改用下面的「重置授权，重新询问」——它会清掉本机对 BigDaddy 的旧授权记录，让系统重新弹出询问框。",
            en: "macOS remembers the earlier “Don't Allow” and won't ask again. In the Privacy & Security → Automation pane that opens, find BigDaddy and tick \(names) underneath it. It applies immediately — no restart needed.\n\nIf those switches don't respond, or BigDaddy isn't listed at all, use “Reset and ask again” below — it clears this Mac's stored decisions for BigDaddy so macOS prompts fresh."
        )
        applyShieldIcon(to: alert)
        alert.addButton(withTitle: Localization.string(zh: "打开系统设置", en: "Open System Settings"))
        alert.addButton(withTitle: Localization.string(zh: "重置授权，重新询问", en: "Reset and ask again"))
        alert.addButton(withTitle: Localization.string(zh: "稍后", en: "Later"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            resetAutomationPermissionsWithConfirmation()
        default:
            break
        }
    }

    /// 「重置授权，重新询问」：先说清代价再动手。
    ///
    /// 重置会清掉本机对 BigDaddy **所有**浏览器的自动化决定（包括已经点过"允许"的），
    /// 之后每个浏览器都要重新同意一次。这个代价必须提前讲明白，不能让家长点完才发现
    /// 原本好好的几个浏览器也要重来。
    private func resetAutomationPermissionsWithConfirmation() {
        let confirm = NSAlert()
        confirm.messageText = Localization.string(zh: "要重置浏览器网址授权吗？", en: "Reset browser URL access?")
        confirm.informativeText = Localization.string(
            zh: "这会清除本机上「BigDaddy 能否读取各浏览器网址」的全部历史决定——包括此前已经允许过的浏览器。清除后，孩子下次使用各个浏览器时，系统会重新弹出授权询问，逐个同意即可。\n\n不影响其它 App 的授权，也不影响辅助功能、屏幕录制这两项权限。",
            en: "This clears every stored decision about whether BigDaddy may read browser addresses on this Mac — including browsers you already allowed. Afterwards macOS will ask again the next time each browser is used.\n\nOther apps' permissions are untouched, as are Accessibility and Screen Recording."
        )
        applyShieldIcon(to: confirm)
        confirm.addButton(withTitle: Localization.string(zh: "重置", en: "Reset"))
        confirm.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = resetAutomationPermissions()
        let done = NSAlert()
        applyShieldIcon(to: done)
        switch result {
        case .success:
            // 重置之后系统重新回到"没问过"状态，本地这几处派生状态也必须跟着归零，
            // 否则预热逻辑会因为 warmedAutomationTargetsKey 还记着账而不再重新询问。
            UserDefaults.standard.removeObject(forKey: Self.warmedAutomationTargetsKey)
            automationDeniedBundleIDs.removeAll()
            automationNoticeShownAt.removeAll()
            rebuildMenu()
            done.messageText = Localization.string(zh: "已重置", en: "Reset complete")
            done.informativeText = Localization.string(
                zh: "本机对 BigDaddy 的浏览器网址授权记录已清除。现在点一次菜单栏里的「⚠️ 浏览器网址未授权 · 点此修复」，系统就会重新逐个弹出授权询问。",
                en: "This Mac's stored browser-URL decisions for BigDaddy are cleared. Click “⚠️ Browser URL access off · Fix it” in the menu bar and macOS will prompt for each browser again."
            )
            done.runModal()
            // 重置后立刻把还开着的浏览器重新问一遍，省得家长再找入口
            warmAutomationConsentIfNeeded()
        case .unavailable:
            // 这个分支只有开发构建会走到（裸二进制没有 Info.plist / bundle id），所以
            // 说明里给命令行是合适的——站在这台机器前的人就是开发者本人。
            //
            // 顺便把"为什么开发构建总是撞上这个"讲明白：裸二进制是 ad-hoc 签名，
            // 每次重新构建 cdhash 都会变，macOS 因此认不出这是同一个程序——旧的授权
            // 记录变成孤儿（在「自动化」面板里还列着，但开关扳不动，因为它绑定的是
            // 一个已经不存在的代码身份），而新的身份又得从头再问一次。构建几次之后，
            // 面板里就会出现好几组同名的 BigDaddy。这跟当初 Keychain 每次构建都重新
            // 弹授权框是同一个根因。
            done.messageText = Localization.string(zh: "开发构建无法定向重置", en: "Can't scope a reset in a dev build")
            done.informativeText = Localization.string(
                zh: """
                当前运行的是未打包的裸二进制，没有 bundle identifier，tccutil 无从定位，因此这里没法只重置 BigDaddy 自己。

                两条出路：
                • 推荐：用 scripts/package.sh 打包成 .app 再测权限相关功能。打包版有固定的 bundle id 和稳定签名，授权记录不会因为重新构建而失效，这颗按钮也就能正常工作。
                • 应急：在终端执行 `tccutil reset AppleEvents`。注意它是全局的——会一并清掉**本机所有 App** 的自动化决定（其它 App 之后也要重新同意一次），所以不放在这里自动执行。
                """,
                en: """
                You're running an unpackaged bare binary with no bundle identifier, so tccutil has nothing to target and this button can't scope a reset to BigDaddy alone.

                Two ways forward:
                • Preferred: package it with scripts/package.sh and test permission-related features there. The packaged build has a fixed bundle id and a stable signature, so grants survive rebuilds and this button works.
                • Escape hatch: run `tccutil reset AppleEvents` in Terminal. It is global — it clears automation decisions for EVERY app on this Mac, so it isn't run automatically from here.
                """
            )
            done.runModal()
        case .failed(let status, let message):
            done.messageText = Localization.string(zh: "重置没有成功", en: "Reset didn't succeed")
            done.informativeText = Localization.string(
                zh: "系统的重置工具返回了错误（代码 \(status)）\(message.isEmpty ? "" : "：\(message)")。请改用「打开系统设置」手动勾选，或联系技术支持。",
                en: "The system reset tool reported an error (code \(status))\(message.isEmpty ? "" : ": \(message)"). Use “Open System Settings” to tick the boxes manually, or contact support."
            )
            done.runModal()
        }
    }

    private enum AutomationResetResult {
        case success
        /// 没有 bundle identifier（开发构建的裸二进制），tccutil 无从定位
        case unavailable
        case failed(status: Int32, message: String)
    }

    /// 调 `tccutil reset AppleEvents <本 App 的 bundle id>` 清掉自身的自动化授权记录。
    ///
    /// 为什么要在 App 里做这件事：家长在「隐私与安全性 → 自动化」里点过"不允许"之后，
    /// 那个面板既不提供删除条目，开关本身在记录陈旧时也可能扳不动，于是普通用户在这里
    /// 彻底没有出路。命令行一条 tccutil 就能解开，但不能指望家长去开终端敲命令。
    ///
    /// 安全边界：只按**自己的 bundle id** 定向重置，动不了别的 App；tccutil 重置的是
    /// "决定记录"而不是"授予权限"，清完之后系统重新回到会询问用户的状态，不存在借此
    /// 自我提权的可能。也因此**不需要**管理员密码。
    private func resetAutomationPermissions() -> AutomationResetResult {
        guard let bundleID = Bundle.main.bundleIdentifier else { return .unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AppleEvents", bundleID]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return .failed(status: -1, message: error.localizedDescription)
        }
        // 先读完管道再 wait：tccutil 输出量极小，但反过来写（先 wait 后读）在管道被写满时
        // 会死锁，这是 Process + Pipe 的经典坑，没必要在这里赌输出一定短。
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("BigDaddy: tccutil reset failed status=\(process.terminationStatus) msg=\(message)")
            return .failed(status: process.terminationStatus, message: message)
        }
        AuditLog.record("AUTOMATION_TCC_RESET bundleID=\(bundleID)")
        return .success
    }

    /// "关于"面板里"已授权？重启客户端"按钮的处理：只负责问一句"确定要重启吗"然后重启，
    /// 不再像之前那样顺带重新打开一次系统设置——如果用户是通过定时截图弹出的系统原生
    /// 提示去设置里授权的，点这里就不该被重新拉回设置页一次，那样很莫名其妙。
    ///
    /// 为什么必须重启：屏幕录制是 macOS 里少数"授权后必须重启 App 才生效"的 TCC 权限。
    /// 运行中的进程里 CGPreflightScreenCaptureAccess() 的结果被进程级缓存——启动时若为
    /// "无权限"，之后哪怕用户在系统设置里勾了授权，本进程仍一直读到旧的 false，既检测
    /// 不到（菜单栏图标不会从 ⚠️ 变 👁️），实际也截不了图。我们没法从代码里判断用户到底
    /// 有没有真的去授权过，所以这个按钮和"前往设置授权"按钮平级并列，让用户自己判断
    /// 该点哪个，而不是猜错了给用户来一套没预期到的流程。
    /// （不会误杀守护：LaunchAgent 未设 KeepAlive，靠 restartApplication 显式重新拉起，
    /// 不会产生双实例；重启是家长授权动作触发、从"关于"面板发起，不是孩子在规避监护。）
    @objc private func promptRestartForScreenRecording() {
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "重启后屏幕录制权限才会生效", en: "Restart to Apply Screen Recording Permission")
        // 明确写出"在哪个开关"，是因为家长最常见的失败不是不肯授权，而是在系统设置里
        // 找错了地方（屏幕录制、辅助功能、文件与文件夹几个面板长得很像）。重启是不可逆
        // 的打断，所以这里也如实说清楚"重启后要是还没生效，就是开关没开成"，省得家长
        // 重启一次发现没用、却不知道下一步该查什么。
        alert.informativeText = Localization.string(
            zh: "屏幕录制权限必须重启 BigDaddy 才会生效，这是 macOS 的限制。\n\n请确认你已经在「系统设置 → 隐私与安全性 → 屏幕录制」里找到 BigDaddy 并打开了它的开关，然后点「立即重启」。\n\n重启后如果菜单栏还是警示图标，说明那个开关没有真的打开，再回到设置里检查一次即可。",
            en: "Screen Recording permission only takes effect after BigDaddy restarts — that's a macOS restriction.\n\nMake sure you've found BigDaddy under System Settings → Privacy & Security → Screen Recording and switched it on, then click Restart Now.\n\nIf the menu bar still shows the warning icon after restarting, that switch didn't actually get turned on — just go back and check it again."
        )
        applyShieldIcon(to: alert)
        alert.addButton(withTitle: Localization.string(zh: "立即重启", en: "Restart Now"))
        alert.addButton(withTitle: Localization.string(zh: "稍后", en: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            restartApplication()
        }
    }
}
