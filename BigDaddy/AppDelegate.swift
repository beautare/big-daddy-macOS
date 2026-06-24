import AppKit
import CryptoKit
import Security

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = BigDaddyClient()
    private var screenshotTimer: Timer?
    private var heartbeatTimer: Timer?
    private var commandTimer: Timer?
    private var countdownTimer: Timer?
    private var countdownSeconds = 300
    private var digitLabels: [NSTextField] = []
    private var countdownLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        client.prepareRuntime()
        statusItem.button?.title = "BD"
        rebuildMenu()
        scheduleTimers()
        Task {
            await client.register()
            let configChanged = await client.refreshConfig()
            await client.sendHeartbeat(event: client.consumePreviousCrash() == nil ? .start : .forceKill)
            await MainActor.run {
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
        menu.addItem(NSMenuItem(title: "Fingerprint: \(client.identity.fingerprint.prefix(12))...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Bind QR", action: #selector(showQr), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Heartbeat: \(client.lastHeartbeatDescription)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Screenshot every \(client.config.screenshotIntervalMins) min", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Destination: \(client.hasScreenshotDestination ? (client.config.destinationEmail ?? "Configured") : "Not configured")", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Send Screenshot Now", action: #selector(sendScreenshotNow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Set Destination Email", action: #selector(setDestinationEmail), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Clear Destination Email", action: #selector(clearDestinationEmail), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Config Path", action: #selector(copyConfigPath), keyEquivalent: "c"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitWithPassword), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func scheduleTimers() {
        screenshotTimer?.invalidate()
        heartbeatTimer?.invalidate()
        commandTimer?.invalidate()

        screenshotTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(client.config.screenshotIntervalMins * 60), repeats: true) { [weak self] _ in
            self?.performScheduledScreenshot()
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
        Task {
            await client.register()
            await MainActor.run {
                let fingerprint = client.identity.fingerprint
                let initialToken = client.bindToken ?? "000000"
                
                let alert = NSAlert()
                alert.messageText = "设备绑定验证"
                alert.informativeText = "请在家长端仪表盘输入下方的 6 位动态验证码，或者复制链接进行绑定。\n\n设备指纹 (Fingerprint):\n\(fingerprint)"
                
                let accessory = self.createAccessoryView(fingerprint: fingerprint, initialToken: initialToken)
                alert.accessoryView = accessory
                
                alert.addButton(withTitle: "复制绑定链接")
                alert.addButton(withTitle: "关闭")
                
                // 初始化倒计时
                self.countdownSeconds = 300
                self.updateCountdownLabelText()
                
                // 启动倒计时 Timer，使用 .common 模式
                self.countdownTimer?.invalidate()
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.tickCountdown()
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
        countdownLabel?.stringValue = "验证码将在 \(timeString) 后自动更新"
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
        alert.messageText = "Exit BigDaddy"
        alert.informativeText = "Enter the parent exit password."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let password = input.stringValue
        Task {
            let success = await client.verifyExitPassword(password)
            await MainActor.run {
                if success {
                    client.sendShutdownSync()
                    NSApp.terminate(nil)
                } else {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Authentication Failed"
                    errorAlert.informativeText = "Invalid exit password or network unreachable."
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            }
        }
    }

    private func installSignalHandlers() {
        signal(SIGTERM) { _ in BigDaddyClient.sharedForceKillPing() }
        signal(SIGINT) { _ in BigDaddyClient.sharedForceKillPing() }
        signal(SIGHUP) { _ in BigDaddyClient.sharedForceKillPing() }
    }
}
