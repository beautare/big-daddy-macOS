import AppKit
import CryptoKit
import Security
import ApplicationServices

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var statusItem: NSStatusItem?
    private let client = BigDaddyClient()
    private var screenshotTimer: Timer?
    private var heartbeatTimer: Timer?
    private var commandTimer: Timer?
    private var countdownTimer: Timer?
    private var countdownSeconds = 300
    private var digitLabels: [NSTextField] = []
    private var countdownLabel: NSTextField?
    private var exitDigitFields: [NSTextField] = []
    private var exitCountdownLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("BigDaddy: applicationDidFinishLaunching started")
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("BigDaddy: StatusItem created")
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        print("BigDaddy: signal handlers installed")
        client.prepareRuntime()
        print("BigDaddy: runtime prepared")
        if #available(macOS 11.0, *) {
            if let image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "BigDaddy") {
                image.isTemplate = true
                statusItem?.button?.image = image
                print("BigDaddy: StatusItem image set successfully")
            } else {
                statusItem?.button?.title = "BD"
                print("BigDaddy: StatusItem image load failed, fallback to BD title")
            }
        } else {
            statusItem?.button?.title = "BD"
            print("BigDaddy: StatusItem title set to BD")
        }
        rebuildMenu()
        print("BigDaddy: menu rebuilt")
        scheduleTimers()
        print("BigDaddy: timers scheduled")
        Task {
            print("BigDaddy: async task background register started")
            await client.register()
            print("BigDaddy: async task background config refresh started")
            let configChanged = await client.refreshConfig()
            print("BigDaddy: async task background heartbeat sending started")
            await client.sendHeartbeat(event: client.consumePreviousCrash() == nil ? .start : .forceKill)
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
        client.sendShutdownSync()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        
        if client.config.bound {
            let statusItem = NSMenuItem(title: "状态: 已受保护", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            
            menu.addItem(NSMenuItem(title: "立即同步截图", action: #selector(sendScreenshotNow), keyEquivalent: "s"))
            menu.addItem(.separator())
            
            menu.addItem(NSMenuItem(title: "设置接收邮箱", action: #selector(setDestinationEmail), keyEquivalent: "e"))
            if client.config.destinationEmail != nil {
                menu.addItem(NSMenuItem(title: "清除接收邮箱", action: #selector(clearDestinationEmail), keyEquivalent: ""))
            }
        } else {
            let statusItem = NSMenuItem(title: "状态: 未绑定", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            
            menu.addItem(NSMenuItem(title: "绑定此 Mac", action: #selector(showQr), keyEquivalent: "b"))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "设置接收邮箱", action: #selector(setDestinationEmail), keyEquivalent: "e"))
        }
        
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "安全退出", action: #selector(quitWithPassword), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func scheduleTimers() {
        screenshotTimer?.invalidate()
        heartbeatTimer?.invalidate()
        commandTimer?.invalidate()

        screenshotTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(client.config.screenshotIntervalMins * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performScheduledScreenshot()
            }
        }
        let heartbeatSeconds = client.config.bound ? client.config.heartbeatActiveSeconds : max(client.config.heartbeatActiveSeconds, 300)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(heartbeatSeconds), repeats: true) { [weak self] _ in
            Task { await self?.client.sendHeartbeat(event: self?.client.isIdle == true ? .idle : .heartbeat) }
        }
        if client.config.bound {
            commandTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { await self?.client.pollCommands() }
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
                    zh: "请在家长端仪表盘输入下方的 6 位动态验证码，或者复制链接进行绑定。\n\n设备指纹 (Fingerprint):\n\(fingerprint)",
                    en: "Please enter the 6-digit dynamic verification code below on the parent dashboard, or copy the link to bind.\n\nDevice Fingerprint:\n\(fingerprint)"
                )
                
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
                    let bindUrlString = "https://dashboard.bigdaddy.com/bind?fingerprint=\(fingerprint)&token=\(currentToken)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bindUrlString, forType: .string)
                }
            }
        }
    }

    private func createAccessoryView(fingerprint: String, initialToken: String) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 16
        container.alignment = .centerX
        container.wantsLayer = true
        
        // 1. 水平数字框的 StackView
        let digitsStack = NSStackView()
        digitsStack.orientation = .horizontal
        digitsStack.spacing = 8
        digitsStack.alignment = .centerY
        
        self.digitLabels.removeAll()
        
        // 苹果的原生验证码框通常是灰白背景、细灰色边框和轻微圆角
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
            
            // 设置固定大小
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 36).isActive = true
            box.heightAnchor.constraint(equalToConstant: 44).isActive = true
            
            let label = NSTextField()
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.alignment = .center
            label.font = NSFont.boldSystemFont(ofSize: 22)
            label.textColor = NSColor.labelColor
            label.stringValue = String(chars[i])
            
            label.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(label)
            
            if let contentView = box.contentView {
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -1) // 轻微校正垂直居中
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
        countdownField.font = NSFont.systemFont(ofSize: 12)
        countdownField.textColor = NSColor.secondaryLabelColor
        self.countdownLabel = countdownField
        
        container.addArrangedSubview(digitsStack)
        container.addArrangedSubview(countdownField)
        
        // 设置容器的宽度，给 Alert 预留足够空间
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 320).isActive = true
        
        return container
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

    @objc private func setDestinationEmail() {
        let alert = NSAlert()
        alert.messageText = "Set Destination Email"
        alert.informativeText = "Enter the parent email address where screenshot notifications will be sent."
        let emailField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        emailField.placeholderString = "parent@example.com"
        emailField.stringValue = client.config.destinationEmail ?? ""
        alert.accessoryView = emailField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.contains("@") {
            let errAlert = NSAlert()
            errAlert.messageText = "Invalid Email"
            errAlert.informativeText = "Please enter a valid email address."
            errAlert.runModal()
            return
        }
        client.saveLocalDestinationEmail(email)
        scheduleTimers()
        rebuildMenu()
    }

    @objc private func clearDestinationEmail() {
        client.clearLocalDestinationEmail()
        rebuildMenu()
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

    private func installSignalHandlers() {
        signal(SIGTERM) { _ in BigDaddyClient.sharedForceKillPing() }
        signal(SIGINT) { _ in BigDaddyClient.sharedForceKillPing() }
        signal(SIGHUP) { _ in BigDaddyClient.sharedForceKillPing() }
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
                zh: "用于分析前台活动窗口及防止软件被恶意关闭",
                en: "Analyze active windows and prevent unauthorized closure"
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
