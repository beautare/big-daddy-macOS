import AppKit
import CryptoKit
import Security
import ApplicationServices
import Sparkle

enum Localization {
    static var isChinese: Bool {
        if let language = Locale.preferredLanguages.first {
            return language.hasPrefix("zh")
        }
        return false
    }

    static func string(zh: String, en: String) -> String {
        return isChinese ? zh : en
    }
}

/// 自绘的盾牌图标：轮廓内部是 2×2 棋盘格，替代系统 SF Symbol 的纯轮廓 shield，
/// 用于菜单栏未截图状态和各处弹窗图标。系统 SF Symbols 里没有棋盘格盾牌这个图形，
/// 用 Bezier 路径手绘 + 裁剪填充实现，可以在任意尺寸下重新栅格化，不依赖位图资源。
enum ShieldIcon {
    private static let aspectRatio: CGFloat = 400.0 / 340.0 // 高/宽

    static func image(pointSize: CGFloat) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize * aspectRatio)
        let image = NSImage(size: size)
        image.lockFocus()

        let inset = pointSize * 0.06
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let shield = path(in: rect)

        NSGraphicsContext.saveGraphicsState()
        shield.addClip()
        let gridCount = 2
        let cellW = rect.width / CGFloat(gridCount)
        let cellH = rect.height / CGFloat(gridCount)
        NSColor.black.setFill()
        for row in 0..<gridCount {
            for col in 0..<gridCount where (row + col) % 2 == 0 {
                NSRect(x: rect.minX + CGFloat(col) * cellW, y: rect.minY + CGFloat(row) * cellH,
                       width: cellW, height: cellH).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.setStroke()
        shield.lineWidth = pointSize * 0.09
        shield.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func path(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height
        let x0 = rect.minX, y0 = rect.minY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0 + 0.16 * w, y: y0 + 1.0 * h))
        path.line(to: NSPoint(x: x0 + 0.84 * w, y: y0 + 1.0 * h))
        path.curve(to: NSPoint(x: x0 + 1.0 * w, y: y0 + 0.68 * h),
                   controlPoint1: NSPoint(x: x0 + 0.96 * w, y: y0 + 1.0 * h),
                   controlPoint2: NSPoint(x: x0 + 1.0 * w, y: y0 + 0.86 * h))
        path.curve(to: NSPoint(x: x0 + 0.5 * w, y: y0),
                   controlPoint1: NSPoint(x: x0 + 1.0 * w, y: y0 + 0.32 * h),
                   controlPoint2: NSPoint(x: x0 + 0.85 * w, y: y0 + 0.12 * h))
        path.curve(to: NSPoint(x: x0, y: y0 + 0.68 * h),
                   controlPoint1: NSPoint(x: x0 + 0.15 * w, y: y0 + 0.12 * h),
                   controlPoint2: NSPoint(x: x0, y: y0 + 0.32 * h))
        path.curve(to: NSPoint(x: x0 + 0.16 * w, y: y0 + 1.0 * h),
                   controlPoint1: NSPoint(x: x0, y: y0 + 0.86 * h),
                   controlPoint2: NSPoint(x: x0 + 0.04 * w, y: y0 + 1.0 * h))
        path.close()
        return path
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate, SPUStandardUserDriverDelegate {
    private var statusItem: NSStatusItem?
    private let client = BigDaddyClient()
    private var screenshotTimer: Timer?
    private var heartbeatTimer: Timer?
    private var commandTimer: Timer?
    private var configTimer: Timer?
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
    /// 菜单打开触发的绑定状态同步做节流，避免频繁点开图标时打网络风暴
    private var lastBindingSyncAt: Date = .distantPast
    /// 绑定检测快轮询任务（展示绑定码/二维码后启动的一段高频探测），持有引用以便取消
    private var bindDetectionTask: Task<Void, Never>?
    /// 后台静默发现并下载完成的更新是否已就绪：SPUStandardUserDriverDelegate 在后台
    /// 检查命中新版本时置位（见 standardUserDriverWillHandleShowingUpdate），驱动"关于"
    /// 面板里额外冒出的高亮"立即安装"按钮；本身不弹任何窗口。
    private var updateReadyToInstall = false
    /// "关于"窗口（自绘 NSWindow，见 showAboutWindow）当前是否已打开，再次点击菜单项时
    /// 先关掉旧的再重建，避免残留一个数据已过期的旧窗口。
    private weak var aboutWindow: NSWindow?
    /// 与"关于"窗口里按钮的 tag 一一对应，点击时按下标取出对应动作执行（见 aboutActionTapped）。
    private var aboutWindowActions: [() -> Void] = []
    // startingUpdater: true 后立即开始按 SUScheduledCheckInterval（Info.plist，当前 1 天）
    // 后台检查；SUEnableAutomaticChecks/SUAutomaticallyUpdate 已在 Info.plist 里直接置为
    // true，跳过 Sparkle 首次运行询问用户的对话框，检查与静默下载都无条件自动进行。
    // userDriverDelegate 指向 self：实现 SPUStandardUserDriverDelegate 的"gentle reminders"
    // 接口（standardUserDriverShouldHandleShowingScheduledUpdate 等），让后台发现/下载
    // 更新的过程完全不弹窗，只在 standardUserDriverWillHandleShowingUpdate 里记录"已就绪"
    // 状态；用户手动点"检查更新…"时不受此限，Sparkle 保证照常展示标准安装流程。
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
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
        LaunchAgentInstaller.installIfNeeded()
        print("BigDaddy: launch agent checked")
        // 菜单栏图标随"截图是否开启"状态变化，孩子端始终可见当前是否处于可截屏状态
        updateStatusItemAppearance()
        print("BigDaddy: StatusItem appearance set")
        // 监听"实际发生截图"事件，触发孩子端即时可见提示
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenshotSent),
            name: BigDaddyClient.screenshotSentNotification, object: nil
        )
        rebuildMenu()
        print("BigDaddy: menu rebuilt")
        presentFirstRunDisclosureIfNeeded()
        scheduleTimers()
        print("BigDaddy: timers scheduled")
        Task {
            print("BigDaddy: async task background started")
            let configChanged = await client.refreshConfig()
            print("BigDaddy: async task background heartbeat sending started")
            // 本次启动永远是 START 事件；如果检测到上次异常终止，通过
            // previousCrashAt 字段"如实补报"，而不是把这次正常启动本身
            // 标记成 FORCE_KILL（那样会让后端把重启误判成刚刚发生的强杀）。
            if let crashedAt = client.detectedPreviousCrash {
                AuditLog.record("PREVIOUS_CRASH_DETECTED at=\(ISO8601DateFormatter().string(from: crashedAt))")
            }
            let reported = await client.sendHeartbeat(event: .start)
            if reported {
                client.clearPreviousCrash()
            }
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

    private func rebuildMenu() {
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

            // 之前拆成"显示本机绑定码"和"输入家长给的码"两条平行菜单项，两者都叫"绑定"，
            // 孩子分不清该点哪个。改成一条入口，点开后再用弹窗把两种方式说清楚。
            menu.addItem(NSMenuItem(
                title: Localization.string(zh: "⚡️ 绑定本设备…", en: "⚡️ Bind This Mac…"),
                action: #selector(showBindEntry), keyEquivalent: "b"
            ))
            menu.addItem(.separator())
        }

        // 版本/配置摘要/心跳/截图倒计时/守护说明/导出记录/检查更新——这些都是次要或
        // 只读信息，收进"关于 BigDaddy"里，一级菜单只留状态和最关键的操作。
        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "关于 BigDaddy…", en: "About BigDaddy…"),
            action: #selector(showAboutWindow), keyEquivalent: ""
        ))
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
        syncBindingStateIfStale()
    }

    /// "关于"窗口：把版本、当前配置摘要、心跳、截图倒计时等只读信息，以及守护说明/
    /// 导出记录/检查更新等次要操作集中在一处，而不是平铺成一堆一级菜单项。
    ///
    /// 改用普通 NSWindow 而不是 NSAlert：NSAlert 的图标+标题是钉死在左上角的固定布局
    /// 区块，就算把 icon 换成透明占位图、messageText 清空，那块区域仍然会保留原本的
    /// 高度，在 LOGO 上方留出一截无法消除的空白（无公开 API 能改这个内部布局）。换成
    /// 自己的窗口后，LOGO/标题/信息行/按钮全部在同一个 NSStackView 里从上到下排列，
    /// 没有任何隐藏的保留区域，居中和间距完全由 createAboutContentView 决定。
    @objc private func showAboutWindow() {
        aboutWindow?.close()

        var actions: [(title: String, handler: () -> Void, prominent: Bool)] = []
        if client.config.bound && client.config.screenshotEnabled {
            actions.append((Localization.string(zh: "立即测试截图命令", en: "Test Screenshot Command"), sendScreenshotNow, false))
        }
        actions.append((Localization.string(zh: "守护说明与采集内容", en: "About This Guardian & What It Collects"), showTransparencyInfo, false))
        actions.append((Localization.string(zh: "导出本机守护记录", en: "Export Local Guardian Log"), exportAuditLog, false))
        // 后台静默下载好的更新已就绪：紧挨着"检查更新…"多冒出一个高亮按钮（蓝底白字），
        // 点击复用 checkForUpdates()——文件已经下载好，Sparkle 会直接跳到"安装并重启"确认。
        if updateReadyToInstall {
            actions.append((Localization.string(zh: "发现新版本，点击安装", en: "Update Ready — Click to Install"), checkForUpdates, true))
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
        aboutWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

        for (label, value) in aboutInfoRows() {
            container.addArrangedSubview(makeInfoRow(label: label, value: value, width: width, labelWidth: labelWidth, rowHeight: rowHeight))
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

    /// "关于"面板只读信息行的数据源：每一行只在对应信息"当下有意义"时才加入。
    private func aboutInfoRows() -> [(String, String)] {
        var rows: [(String, String)] = []
        if client.config.bound {
            rows.append((Localization.string(zh: "状态", en: "Status"),
                         Localization.string(zh: "已受保护", en: "Protected")))
            rows.append((
                Localization.string(zh: "截图", en: "Screenshots"),
                client.config.screenshotEnabled
                    ? Localization.string(zh: "已开启（家长可远程截屏）", en: "ON (parent can capture)")
                    : Localization.string(zh: "未开启", en: "OFF")
            ))
            rows.append((Localization.string(zh: "最近心跳", en: "Last heartbeat"), client.lastHeartbeatDescription))
            if client.config.screenshotEnabled {
                if let fireDate = screenshotTimer?.fireDate {
                    let remaining = max(0, Int(fireDate.timeIntervalSinceNow))
                    rows.append((
                        Localization.string(zh: "下次截屏", en: "Next screenshot"),
                        String(format: Localization.string(zh: "%02d:%02d 后", en: "in %02d:%02d"),
                               remaining / 60, remaining % 60)
                    ))
                }
                rows.append((
                    Localization.string(zh: "截屏间隔", en: "Interval"),
                    Localization.string(zh: "\(client.config.screenshotIntervalMins) 分钟",
                                        en: "\(client.config.screenshotIntervalMins) min")
                ))
            }
            let channels = client.config.notificationChannels
            var channelNames: [String] = []
            if !(channels.email ?? "").isEmpty { channelNames.append(Localization.string(zh: "邮件", en: "Email")) }
            if !(channels.telegramChatId ?? "").isEmpty { channelNames.append("Telegram") }
            if !(channels.whatsappPhone ?? "").isEmpty { channelNames.append("WhatsApp") }
            if !channelNames.isEmpty {
                rows.append((
                    Localization.string(zh: "通知渠道", en: "Notify via"),
                    channelNames.joined(separator: Localization.string(zh: "、", en: ", "))
                ))
            }
        } else {
            rows.append((Localization.string(zh: "状态", en: "Status"),
                         Localization.string(zh: "尚未绑定家长账号", en: "Unbound")))
        }
        rows.append((Localization.string(zh: "版本", en: "Version"), AppVersion.current))
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
                let changed = self.client.credentialsInvalid ? false : await self.client.refreshConfig()
                if self.client.config.bound {
                    // 绑定成功：立即发送一次心跳，让后端即时感知设备上线
                    await self.client.sendHeartbeat(event: .start)
                    await MainActor.run {
                        self.scheduleTimers()
                        self.rebuildMenu()
                        self.updateStatusItemAppearance()
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
    /// - off: 盾牌；on: 眼睛（正被家长可视）；capturing: 相机（此刻正在截屏）；
    /// - missingPermission: 家长已开启截图但系统权限未授权，三角警示号提示"配置了但实际不生效"。
    private func updateStatusItemAppearance(capturing: Bool = false) {
        guard let button = statusItem?.button else { return }
        let on = client.config.screenshotEnabled
        let missingPermission = on && !checkScreenRecordingPermission()
        if #available(macOS 11.0, *) {
            let desc: String
            let image: NSImage?
            if capturing {
                image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
                desc = Localization.string(zh: "BigDaddy 正在截图", en: "BigDaddy capturing screenshot")
            } else if missingPermission {
                image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                desc = Localization.string(zh: "BigDaddy 截图已开启但缺少系统权限", en: "BigDaddy screenshots on but missing system permission")
            } else if on {
                image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
                desc = Localization.string(zh: "BigDaddy 截图已开启", en: "BigDaddy screenshots on")
            } else {
                image = ShieldIcon.image(pointSize: 16)
                desc = "BigDaddy"
            }
            if let image {
                image.isTemplate = true
                image.accessibilityDescription = desc
                button.image = image
                button.title = ""
                return
            }
        }
        button.image = nil
        button.title = capturing ? "BD●REC" : (missingPermission ? "BD⚠" : (on ? "BD●" : "BD"))
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

    /// 本机通知（无需额外权限），用于把"发生了什么"即时告知使用本机的孩子。
    private func postLocalNotice(title: String, body: String) {
        let notice = NSUserNotification()
        notice.title = title
        notice.informativeText = body
        NSUserNotificationCenter.default.deliver(notice)
    }

    // 跟踪 IDLE/RESUME 状态转换
    private var wasIdle = false

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

    private func scheduleTimers() {
        screenshotTimer?.invalidate()

        // 定时截图（由后端 screenshotEnabled 控制，调度本身照常）
        screenshotTimer = scheduleCommonModeTimer(
            interval: TimeInterval(client.config.screenshotIntervalMins * 60),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performScheduledScreenshot() }
        }

        scheduleNextHeartbeat()
        scheduleNextCommandPoll()

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
                let isIdle = await self.client.isIdle
                if !isIdle && previouslyIdle {
                    // 从 IDLE 恢复 → 立即发送 RESUME 并拉取最新配置，恢复正常节奏
                    await self.client.sendHeartbeat(event: .resume)
                    _ = await self.client.refreshConfig()
                } else {
                    await self.client.sendHeartbeat(event: isIdle ? .idle : .heartbeat)
                }
                self.wasIdle = isIdle
                self.scheduleNextHeartbeat()
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
        let boundBefore = client.config.bound
        let invalidBefore = client.credentialsInvalid
        let before = client.config.screenshotEnabled
        // 凭据失效时签名通道全断，config 轮询收不到任何信号（包括解绑）。register 不签名：
        // 家长解绑后，后端会重新接受本机 secret（未绑定设备允许换钥），凭据在这里自动恢复，
        // 随后回到常规配置轮询——不需要重启客户端。
        if client.credentialsInvalid {
            await client.register()
        }
        var changed = false
        if !client.credentialsInvalid {
            changed = await client.refreshConfig()
        }
        let boundChanged = client.config.bound != boundBefore
        let credentialsChanged = client.credentialsInvalid != invalidBefore
        guard changed || boundChanged || credentialsChanged else { return }
        let after = client.config.screenshotEnabled
        await MainActor.run {
            rebuildMenu()
            updateStatusItemAppearance()
            triggerImmediateCommandPollIfNeeded()
            if boundChanged {
                // 心跳/命令轮询的节奏依赖 bound，翻转后立即切换调度
                scheduleTimers()
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
                postLocalNotice(
                    title: after
                        ? Localization.string(zh: "家长已开启截图", en: "Parent turned screenshots ON")
                        : Localization.string(zh: "家长已关闭截图", en: "Parent turned screenshots OFF"),
                    body: after
                        ? Localization.string(zh: "家长现在可以远程截屏，本机会持续记录每一次截图。",
                                              en: "Your parent can now capture screenshots; every capture is logged on this Mac.")
                        : Localization.string(zh: "截图功能已停止。",
                                              en: "Screenshot capture has been turned off.")
                )
            }
        }
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
                        _ = try await client.refreshConfig()
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
        Task { await client.captureAndSendScreenshot(reason: "manual") }
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate（后台静默更新的 gentle reminders）
    //
    // Sparkle 从任意线程回调这几个方法，协议要求因此是 nonisolated；AppDelegate 整体是
    // @MainActor，nonisolated 方法不能直接读写 @MainActor 隔离的存储属性，需要状态变更的
    // 那个方法用 Task { @MainActor in } 跳回主线程再赋值（见 standardUserDriverWillHandleShowingUpdate）。
    // （这里不用 Swift 较新版本才支持的"隔离一致性"写法 `@MainActor SPUStandardUserDriverDelegate`，
    // 是因为 CI 的工具链版本还不认识这个语法，会直接编译失败——nonisolated + Task 跳转是
    // 更通用、旧工具链也能编译的做法。）

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 后台/计划内检查发现新版本时，是否交给 Sparkle 标准界面弹窗展示——返回 false，
    /// 改由下面的 standardUserDriverWillHandleShowingUpdate 自行处理（也就是什么都不弹）。
    /// 这个开关只对后台触发的检查生效，用户手动点"检查更新…"永远走标准弹窗（Sparkle 保证，
    /// 见该方法文档：This method is not called for user-initiated update checks）。
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// 上面返回 false 后，Sparkle 在这里告知"这次不由它弹窗"：下载完成（.downloaded）
    /// 或已开始静默安装（.installing）时置位 updateReadyToInstall，下次打开"关于"面板
    /// 就会多出一个高亮的"发现新版本，点击安装"按钮；点击后复用 checkForUpdates()，
    /// 因为文件已经下载好，Sparkle 会直接跳到"安装并重启"确认，不会重新下载。
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        guard state.stage == .downloaded || state.stage == .installing else { return }
        Task { @MainActor in
            self.updateReadyToInstall = true
        }
    }

    /// 知情透明：向使用本机的孩子清楚说明这是什么、谁能看到、采集了什么、如何暂停
    @objc private func showTransparencyInfo() {
        let alert = NSAlert()
        alert.messageText = Localization.string(
            zh: "关于本机的家庭守护",
            en: "About the Family Guardian on This Mac"
        )
        // 采集说明随当前真实状态变化，避免"文案说没开、实际已开"的表里不一
        let shotStatusZh = client.config.screenshotEnabled
            ? "截图当前【已开启】：家长可远程截屏，每一张都会记录在本机。"
            : "截图当前【未开启】：仅生成活动应用与窗口标题的使用摘要，不截屏。"
        let shotStatusEn = client.config.screenshotEnabled
            ? "Screenshots are currently ON: your parent can capture the screen; every capture is logged here."
            : "Screenshots are currently OFF: only usage summaries of the active app/window are collected, no screen capture."
        alert.informativeText = Localization.string(
            zh: """
            这台 Mac 正在运行 BigDaddy 家庭守护，由你的家长（法定监护人）在你知情的前提下与你共同使用。

            • 采集内容：当前活动应用与窗口标题的使用摘要。\(shotStatusZh)
            • 谁能看到：仅与本设备完成绑定的家长本人。服务器只做中转，不保存截图原图。
            • 你的知情权：菜单栏图标会随截图开关变化；开启后菜单会常驻显示提示，每次实际截图都会弹出通知并写入“本机守护记录”，你可以随时导出查看。
            • 暂停/停止：请与家长沟通，由家长在仪表盘生成退出验证码或解除绑定。
            """,
            en: """
            This Mac runs BigDaddy Family Guardian, used with your knowledge by your parent (legal guardian).

            • What it collects: usage summaries of the active app and window title. \(shotStatusEn)
            • Who can see it: only the parent bound to this device. The server relays and never stores screenshots.
            • Your visibility: the menu bar icon changes with the screenshot switch; when on, the menu shows a standing notice, and every capture pops a notification and is written to the local Guardian Log you can export anytime.
            • Pause/stop: talk to your parent, who can issue an exit code or unbind the device in the dashboard.
            """
        )
        alert.addButton(withTitle: Localization.string(zh: "我知道了", en: "Got it"))
        alert.addButton(withTitle: Localization.string(zh: "导出本机守护记录", en: "Export Local Guardian Log"))
        if alert.runModal() == .alertSecondButtonReturn {
            exportAuditLog()
        }
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
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "退出 BigDaddy 客户端", en: "Exit BigDaddy Client")
        alert.informativeText = Localization.string(
            zh: "请在家长控制端 Dashboard 生成安全退出验证码，输入后即可正常关闭客户端。",
            en: "Please generate a secure exit verification code on the parent dashboard, enter it to close the client."
        )
        
        let accessory = self.createExitAccessoryView()
        alert.accessoryView = accessory
        
        alert.addButton(withTitle: Localization.string(zh: "安全退出", en: "Secure Exit"))
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

        guard response == .alertFirstButtonReturn else { return }

        let code = self.exitDigitFields.map { $0.stringValue }.joined()
        if code.count < 6 {
            let errorAlert = NSAlert()
            errorAlert.messageText = Localization.string(zh: "验证失败", en: "Verification Failed")
            errorAlert.informativeText = Localization.string(zh: "请输入完整的 6 位验证码。", en: "Please enter the complete 6-digit verification code.")
            errorAlert.addButton(withTitle: Localization.string(zh: "确认", en: "Confirm"))
            errorAlert.runModal()
            return
        }
        
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

    private func createPermissionCheckerView(hasAccessibility: Bool) -> NSView {
        // 创建具有明确 frame 的普通 NSView 作为最外层容器，撑开 NSAlert 的 accessoryView 空间
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
            isGranted: hasAccessibility,
            action: #selector(openAccessibilitySettings)
        )
        container.addArrangedSubview(accRow)
        
        return parentView
    }
    
    private func createPermissionRow(title: String, description: String, isGranted: Bool, action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 380).isActive = true
        
        // 1. 状态图标
        let statusLabel = NSTextField(labelWithString: isGranted ? "✅" : "❌")
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
        
        if isGranted {
            button.title = Localization.string(zh: "已授权", en: "Authorized")
            button.isEnabled = false
        } else {
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

    private func checkAndRequestPermissions() -> Bool {
        let hasAccessibility = AXIsProcessTrustedWithOptions(nil)
        
        if hasAccessibility {
            return true
        }
        
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "需要系统辅助功能权限", en: "Accessibility Permission Required")
        alert.informativeText = Localization.string(
            zh: "为了能够正常守护您的孩子，BigDaddy 客户端需要辅助功能权限支持。请点击右侧的“去授权”按钮，在弹出的系统设置中勾选允许 `BigDaddy`，然后点击“我已开启，继续绑定”。",
            en: "To protect your child, BigDaddy needs Accessibility permission. Click 'Authorize' to grant access in System Settings, then click 'I've enabled, continue'."
        )
        
        let accessory = createPermissionCheckerView(hasAccessibility: hasAccessibility)
        alert.accessoryView = accessory
        
        alert.addButton(withTitle: Localization.string(zh: "我已开启，继续绑定", en: "I've enabled, continue"))
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // 家长配置好后点击“继续”，递归刷新自检状态
            return checkAndRequestPermissions()
        }
        
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
