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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
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
    private var qrImageView: NSImageView?
    private var exitDigitFields: [NSTextField] = []
    private var exitCountdownLabel: NSTextField?
    /// 必须持有引用，否则 DispatchSourceSignal 会被提前释放、信号监听失效
    private var signalSources: [DispatchSourceSignal] = []
    // 菜单里需要"打开前动态刷新"的只读展示项（心跳状态/下次截屏倒计时/当前配置摘要）
    private var heartbeatStatusMenuItem: NSMenuItem?
    private var nextScreenshotMenuItem: NSMenuItem?
    private var configSummaryMenuItem: NSMenuItem?
    // startingUpdater: true 后立即开始按 SUScheduledCheckInterval 后台检查；
    // 是否自动检查由 Sparkle 首次运行时弹出的系统对话框询问用户（Info.plist 未设置
    // SUEnableAutomaticChecks，交由 Sparkle 自行询问并记住用户的选择）。
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
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
        _ = updaterController // 触发 lazy 初始化，启动 Sparkle 后台更新检查
        print("BigDaddy: Sparkle updater started")
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
            print("BigDaddy: async task background register started")
            await client.register()
            print("BigDaddy: async task background config refresh started")
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
            }
        }
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

        if client.config.bound {
            let statusItem = NSMenuItem(
                title: Localization.string(zh: "状态: 已受保护", en: "Status: Protected"),
                action: nil, keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            // 常驻可见提示：截图开启时，孩子在菜单里一眼可见"家长可远程截屏"
            let screenshotStateItem = NSMenuItem(
                title: client.config.screenshotEnabled
                    ? Localization.string(zh: "📸 截图已开启：家长可远程截屏（本机会记录）",
                                          en: "📸 Screenshots ON: parent can capture (logged on this Mac)")
                    : Localization.string(zh: "截图: 未开启", en: "Screenshots: OFF"),
                action: nil, keyEquivalent: ""
            )
            screenshotStateItem.isEnabled = false
            menu.addItem(screenshotStateItem)

            // 运行状态：最近一次心跳送达时间，孩子/家长一眼可见守护是否还在正常运作
            let heartbeatItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            heartbeatItem.isEnabled = false
            menu.addItem(heartbeatItem)
            self.heartbeatStatusMenuItem = heartbeatItem

            // 下一次截屏倒计时（仅截图开启时有意义）
            if client.config.screenshotEnabled {
                let countdownItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                countdownItem.isEnabled = false
                menu.addItem(countdownItem)
                self.nextScreenshotMenuItem = countdownItem
            } else {
                self.nextScreenshotMenuItem = nil
            }

            // 当前配置只读展示：修改集中在家长 Dashboard，这里只做展示
            let configSummaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            configSummaryItem.isEnabled = false
            menu.addItem(configSummaryItem)
            self.configSummaryMenuItem = configSummaryItem

            menu.addItem(NSMenuItem(
                title: Localization.string(zh: "立即测试截图命令", en: "Test Screenshot Command"),
                action: #selector(sendScreenshotNow), keyEquivalent: "s"
            ))
            menu.addItem(.separator())
        } else {
            let statusItem = NSMenuItem(
                title: Localization.string(zh: "状态: 未绑定", en: "Status: Unbound"),
                action: nil, keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            menu.addItem(NSMenuItem(
                title: Localization.string(zh: "绑定此 Mac (扫码)", en: "Bind This Mac (QR)"),
                action: #selector(showQr), keyEquivalent: "b"
            ))
            menu.addItem(NSMenuItem(
                title: Localization.string(zh: "输入家长绑定码", en: "Enter Parent Bind Code"),
                action: #selector(showBindCodeInput), keyEquivalent: ""
            ))
            menu.addItem(.separator())
            self.heartbeatStatusMenuItem = nil
            self.nextScreenshotMenuItem = nil
            self.configSummaryMenuItem = nil
        }

        // 知情透明：任何状态下孩子都能查看"守护说明"和导出"本机守护记录"
        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "守护说明与采集内容", en: "About This Guardian & What It Collects"),
            action: #selector(showTransparencyInfo), keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "导出本机守护记录", en: "Export Local Guardian Log"),
            action: #selector(exportAuditLog), keyEquivalent: ""
        ))
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(
            title: Localization.string(zh: "版本 \(version)", en: "Version \(version)"),
            action: nil, keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "检查更新…", en: "Check for Updates…"),
            action: #selector(checkForUpdates), keyEquivalent: ""
        ))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: Localization.string(zh: "安全退出", en: "Secure Exit"),
            action: #selector(quitWithPassword), keyEquivalent: "q"
        ))
        statusItem?.menu = menu
        updateStatusItemAppearance()
        refreshDynamicMenuItems()
    }

    /// 打开菜单前刷新一次动态项，确保心跳状态/倒计时/配置摘要是"打开那一刻"的真实值，
    /// 而不需要靠后台不断重建整个菜单来维持新鲜度。
    private func refreshDynamicMenuItems() {
        heartbeatStatusMenuItem?.title = Localization.string(
            zh: "最近心跳: \(client.lastHeartbeatDescription)",
            en: "Last heartbeat: \(client.lastHeartbeatDescription)"
        )

        if let item = nextScreenshotMenuItem {
            if let fireDate = screenshotTimer?.fireDate {
                let remaining = max(0, Int(fireDate.timeIntervalSinceNow))
                let mm = remaining / 60
                let ss = remaining % 60
                item.title = Localization.string(
                    zh: String(format: "下次截屏: %02d:%02d 后", mm, ss),
                    en: String(format: "Next screenshot in %02d:%02d", mm, ss)
                )
            } else {
                item.title = Localization.string(zh: "下次截屏: 未安排", en: "Next screenshot: not scheduled")
            }
        }

        if let item = configSummaryMenuItem {
            let channels = client.config.notificationChannels
            let hasChannel = !(channels.email ?? "").isEmpty || !(channels.telegramChatId ?? "").isEmpty
            let channelDesc = hasChannel
                ? Localization.string(zh: "已配置", en: "configured")
                : Localization.string(zh: "未配置", en: "not configured")
            item.title = Localization.string(
                zh: "当前配置: 截屏间隔 \(client.config.screenshotIntervalMins) 分钟 · 通知渠道\(channelDesc)",
                en: "Config: every \(client.config.screenshotIntervalMins) min · channel \(channelDesc)"
            )
        }
    }

    /// 用户点开菜单栏图标的那一刻，把心跳状态/倒计时/配置摘要刷新成最新值。
    func menuWillOpen(_ menu: NSMenu) {
        refreshDynamicMenuItems()
    }

    /// 让菜单栏图标反映当前"截图是否开启 / 是否正在截图 / 权限是否缺失"，作为孩子端常驻可见指示。
    /// - off: 盾牌；on: 眼睛（正被家长可视）；capturing: 相机（此刻正在截屏）；
    /// - missingPermission: 家长已开启截图但系统权限未授权，三角警示号提示"配置了但实际不生效"。
    private func updateStatusItemAppearance(capturing: Bool = false) {
        guard let button = statusItem?.button else { return }
        let on = client.config.screenshotEnabled
        let missingPermission = on && !checkScreenRecordingPermission()
        if #available(macOS 11.0, *) {
            let symbol: String
            let desc: String
            if capturing {
                symbol = "camera.fill"; desc = Localization.string(zh: "BigDaddy 正在截图", en: "BigDaddy capturing screenshot")
            } else if missingPermission {
                symbol = "exclamationmark.triangle.fill"
                desc = Localization.string(zh: "BigDaddy 截图已开启但缺少系统权限", en: "BigDaddy screenshots on but missing system permission")
            } else if on {
                symbol = "eye.fill"; desc = Localization.string(zh: "BigDaddy 截图已开启", en: "BigDaddy screenshots on")
            } else {
                symbol = "shield.fill"; desc = "BigDaddy"
            }
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc) {
                image.isTemplate = true
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
            Task { @MainActor in self?.updateStatusItemAppearance() }
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

    private func scheduleTimers() {
        screenshotTimer?.invalidate()

        // 定时截图（由后端 screenshotEnabled 控制，调度本身照常）
        screenshotTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(client.config.screenshotIntervalMins * 60),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.performScheduledScreenshot() }
        }

        scheduleNextHeartbeat()
        scheduleNextCommandPoll()

        // 定期拉取配置，使家长在后端的开启/撤销近实时生效，并让状态变化对孩子端可见
        configTimer?.invalidate()
        configTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.pollConfigForChildVisibility() }
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
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            let previouslyIdle = self.wasIdle
            Task {
                let isIdle = await self.client.isIdle
                if !isIdle && previouslyIdle {
                    // 从 IDLE 恢复 → 立即发送 RESUME 并拉取最新配置，恢复正常节奏
                    await self.client.sendHeartbeat(event: .resume)
                    _ = await self.client.refreshConfig()
                } else {
                    await self.client.sendHeartbeat(event: isIdle ? .idle : .heartbeat)
                }
                await MainActor.run {
                    self.wasIdle = isIdle
                    self.scheduleNextHeartbeat()
                    self.triggerImmediateCommandPollIfNeeded()
                }
            }
        }
    }

    /// 命令轮询自我重排：活跃态 30 秒一次，空闲态降到 5 分钟一次。
    private func scheduleNextCommandPoll() {
        commandTimer?.invalidate()
        guard client.config.bound else { return }
        let interval: TimeInterval = wasIdle ? 300 : 30
        commandTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
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
        let before = client.config.screenshotEnabled
        let changed = await client.refreshConfig()
        guard changed else { return }
        let after = client.config.screenshotEnabled
        await MainActor.run {
            rebuildMenu()
            updateStatusItemAppearance()
            triggerImmediateCommandPollIfNeeded()
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

    @objc private func showQr() {
        guard checkAndRequestPermissions() else { return }
        
        Task {
            await client.register()
            await MainActor.run {
                let fingerprint = client.identity.fingerprint
                let initialToken = client.bindToken ?? "000000"
                let alert = NSAlert()
                alert.messageText = Localization.string(zh: "设备绑定验证", en: "Device Binding Verification")
                alert.informativeText = Localization.string(
                    zh: "请在家长端仪表盘输入下方的 6 位动态验证码，或者复制链接进行绑定。",
                    en: "Please enter the 6-digit dynamic verification code below on the parent dashboard, or copy the link to bind."
                )
                
                if #available(macOS 11.0, *) {
                    if let image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "BigDaddy") {
                        image.isTemplate = true
                        alert.icon = image
                    }
                }
                
                let accessory = self.createAccessoryView(fingerprint: fingerprint, initialToken: initialToken)
                alert.accessoryView = accessory
                
                alert.addButton(withTitle: Localization.string(zh: "复制绑定链接", en: "Copy Binding Link"))
                alert.addButton(withTitle: Localization.string(zh: "关闭", en: "Close"))
                
                // 初始化倒计时
                self.countdownSeconds = 300
                self.updateCountdownLabelText()
                
                // 启动倒计时 Timer，使用 .common 模式
                self.countdownTimer?.invalidate()
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.tickCountdown()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.countdownTimer = timer
                
                // 运行 Alert Modal
                let response = alert.runModal()
                
                // Modal 结束，销毁计时器
                self.countdownTimer?.invalidate()
                self.countdownTimer = nil
                
                if response == .alertFirstButtonReturn {
                    let currentToken = self.digitLabels.map { $0.stringValue }.joined()
                    let bindUrlString = "bigdaddy://bind?fingerprint=\(fingerprint)&token=\(currentToken)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bindUrlString, forType: .string)
                }
            }
        }
    }

    private func createAccessoryView(fingerprint: String, initialToken: String) -> NSView {
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 380))
        
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
        
        // 1. 展示二维码 (方式A)
        let qrView = NSImageView()
        qrView.image = client.generateBindQRCode()
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        self.qrImageView = qrView
        
        let qrDescLabel = NSTextField()
        qrDescLabel.isEditable = false
        qrDescLabel.isSelectable = false
        qrDescLabel.isBordered = false
        qrDescLabel.drawsBackground = false
        qrDescLabel.alignment = .center
        qrDescLabel.font = NSFont.systemFont(ofSize: 11)
        qrDescLabel.textColor = NSColor.secondaryLabelColor
        qrDescLabel.stringValue = Localization.string(
            zh: "家长扫描上述二维码完成绑定",
            en: "Parent: scan the QR code above to bind"
        )
        
        // 分割说明：或动态输入验证码
        let codeDescLabel = NSTextField()
        codeDescLabel.isEditable = false
        codeDescLabel.isSelectable = false
        codeDescLabel.isBordered = false
        codeDescLabel.drawsBackground = false
        codeDescLabel.alignment = .center
        codeDescLabel.font = NSFont.boldSystemFont(ofSize: 11)
        codeDescLabel.textColor = NSColor.labelColor
        codeDescLabel.stringValue = Localization.string(
            zh: "或在家长端输入 6 位验证码",
            en: "Or enter the 6-digit code on the parent dashboard"
        )
        
        // 2. 水平数字框的 StackView
        let digitsStack = NSStackView()
        digitsStack.orientation = .horizontal
        digitsStack.spacing = 8
        digitsStack.alignment = .centerY
        
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
            
            if let contentView = box.contentView {
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -1)
                ])
            }
            
            digitsStack.addArrangedSubview(box)
            self.digitLabels.append(label)
        }
        
        // 3. 倒计时文本框
        let countdownField = NSTextField()
        countdownField.isEditable = false
        countdownField.isSelectable = false
        countdownField.isBordered = false
        countdownField.drawsBackground = false
        countdownField.alignment = .center
        countdownField.font = NSFont.systemFont(ofSize: 11)
        countdownField.textColor = NSColor.secondaryLabelColor
        self.countdownLabel = countdownField
        
        // 4. 设备识别码文本框
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
        
        container.addArrangedSubview(qrView)
        container.addArrangedSubview(qrDescLabel)
        container.addArrangedSubview(codeDescLabel)
        container.addArrangedSubview(digitsStack)
        container.addArrangedSubview(countdownField)
        container.addArrangedSubview(deviceIdField)
        
        return parentView
    }

    private func tickCountdown() {
        if countdownSeconds > 0 {
            countdownSeconds -= 1
            updateCountdownLabelText()
        } else {
            // 倒计时归零，静默获取新验证码
            Task {
                await refreshBindToken()
            }
        }
    }

    private func refreshBindToken() async {
        await client.register()
        let token = client.bindToken ?? "000000"
        await MainActor.run {
            self.countdownSeconds = 300
            self.updateDigitBoxes(with: token)
            self.updateCountdownLabelText()
        }
    }

    private func updateDigitBoxes(with token: String) {
        let paddedToken = token.padding(toLength: 6, withPad: "0", startingAt: 0)
        let chars = Array(paddedToken)
        for i in 0..<min(chars.count, digitLabels.count) {
            digitLabels[i].stringValue = String(chars[i])
        }
        qrImageView?.image = client.generateBindQRCode()
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
        
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        inputField.placeholderString = "000000"
        inputField.alignment = .center
        inputField.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        alert.accessoryView = inputField
        
        alert.addButton(withTitle: Localization.string(zh: "确认绑定", en: "Confirm Bind"))
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))
        
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
            zh: "验证码将在 \(timeString) 后自动更新",
            en: "Verification code will auto-update in \(timeString)"
        )
    }

    @objc private func sendScreenshotNow() {
        Task { await client.captureAndSendScreenshot(reason: "manual") }
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
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
        
        // 启动倒计时 Timer
        self.countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickExitCountdown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.countdownTimer = timer
        
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
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 16
        container.alignment = .centerX
        container.wantsLayer = true
        
        let digitsStack = NSStackView()
        digitsStack.orientation = .horizontal
        digitsStack.spacing = 8
        digitsStack.alignment = .centerY
        
        self.exitDigitFields.removeAll()
        
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
            
            if let contentView = box.contentView {
                NSLayoutConstraint.activate([
                    field.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                    field.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -1)
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
        
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 320).isActive = true
        
        return container
    }

    private func tickExitCountdown() {
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

    func controlTextDidChange(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        
        var text = textField.stringValue
        if text.count > 1 {
            text = String(text.prefix(1))
            textField.stringValue = text
        }
        
        let filtered = text.filter { $0.isNumber }
        if filtered != text {
            textField.stringValue = filtered
            text = filtered
        }
        
        if text.count == 1 {
            if let index = exitDigitFields.firstIndex(of: textField) {
                if index < 5 {
                    textField.window?.makeFirstResponder(exitDigitFields[index + 1])
                }
            }
        } else if text.isEmpty {
            if let index = exitDigitFields.firstIndex(of: textField) {
                if index > 0 {
                    textField.window?.makeFirstResponder(exitDigitFields[index - 1])
                }
            }
        }
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
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // 尝试以 1x1 像素做真实截屏校验，绕过 ad-hoc / 无 bundle ID 导致的 preflight 错误
        if CGDisplayCreateImage(CGMainDisplayID(), rect: CGRect(x: 0, y: 0, width: 1, height: 1)) != nil {
            return true
        }
        return false
    }

    private func createPermissionCheckerView(hasAccessibility: Bool, hasScreenCapture: Bool) -> NSView {
        // 创建具有明确 frame 的普通 NSView 作为最外层容器，撑开 NSAlert 的 accessoryView 空间
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        
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
        
        // 屏幕录制行
        let screenRow = createPermissionRow(
            title: Localization.string(zh: "屏幕录制权限", en: "Screen Recording Permission"),
            description: Localization.string(
                zh: "用于定时捕捉屏幕图像以上报至网页控制端",
                en: "Periodically capture screenshots for parental dashboard"
            ),
            isGranted: hasScreenCapture,
            action: #selector(openScreenRecordingSettings)
        )
        container.addArrangedSubview(screenRow)
        
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
        let hasScreenCapture = checkScreenRecordingPermission()
        
        if hasAccessibility && hasScreenCapture {
            return true
        }
        
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "需要系统权限", en: "System Permissions Required")
        alert.informativeText = Localization.string(
            zh: "为了能够正常守护您的孩子，BigDaddy 客户端需要以下权限支持。请点击右侧的“去授权”按钮，在弹出的系统设置中勾选允许 `BigDaddy`，然后点击“我已开启，继续绑定”。",
            en: "To protect your child, BigDaddy needs the following permissions. Click 'Authorize' to grant access in System Settings, then click 'I've enabled, continue'."
        )
        
        let accessory = createPermissionCheckerView(hasAccessibility: hasAccessibility, hasScreenCapture: hasScreenCapture)
        alert.accessoryView = accessory
        
        alert.addButton(withTitle: Localization.string(zh: "我已开启，继续绑定", en: "I've enabled, continue"))
        alert.addButton(withTitle: Localization.string(zh: "取消", en: "Cancel"))
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let hasAccessibilityNow = AXIsProcessTrustedWithOptions(nil)
            let hasScreenCaptureNow = checkScreenRecordingPermission()
            
            if hasAccessibilityNow && !hasScreenCaptureNow {
                let restartAlert = NSAlert()
                restartAlert.messageText = Localization.string(zh: "需要重启应用生效", en: "Restart Required")
                restartAlert.informativeText = Localization.string(
                    zh: "如果您已在系统设置中允许了屏幕录制权限，请点击“重启应用”使其生效；否则请点击“返回”先去授权。",
                    en: "If you have enabled screen recording in System Settings, click 'Restart App' to apply it; otherwise click 'Back' to authorize first."
                )
                restartAlert.addButton(withTitle: Localization.string(zh: "重启应用", en: "Restart App"))
                restartAlert.addButton(withTitle: Localization.string(zh: "返回", en: "Back"))
                
                if restartAlert.runModal() == .alertFirstButtonReturn {
                    restartApplication()
                }
            }
            
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
