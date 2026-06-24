import AppKit
import CryptoKit
import Security

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
        alert.messageText = "退出 BigDaddy 客户端"
        alert.informativeText = "请在家长控制端 Dashboard 生成安全退出验证码，输入后即可正常关闭客户端。"
        
        let accessory = self.createExitAccessoryView()
        alert.accessoryView = accessory
        
        alert.addButton(withTitle: "安全退出")
        alert.addButton(withTitle: "取消")
        
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
            errorAlert.messageText = "验证失败"
            errorAlert.informativeText = "请输入完整的 6 位验证码。"
            errorAlert.addButton(withTitle: "确认")
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
                    errorAlert.messageText = "认证失败"
                    errorAlert.informativeText = "退出验证码不正确或已过期，请重新在家长端生成后重试。"
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
            exitCountdownLabel?.stringValue = "验证码已超时失效，请关闭此窗口并重新获取"
            exitCountdownLabel?.textColor = NSColor.systemRed
        }
    }

    private func updateExitCountdownLabelText() {
        guard countdownSeconds > 0 else { return }
        let minutes = countdownSeconds / 60
        let seconds = countdownSeconds % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)
        exitCountdownLabel?.stringValue = "验证码将在 \(timeString) 后失效"
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
}
