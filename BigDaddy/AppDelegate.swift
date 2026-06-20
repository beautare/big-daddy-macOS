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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        client.prepareRuntime()
        statusItem.button?.title = "BD"
        rebuildMenu()
        Task {
            await client.register()
            await client.refreshConfig()
            await client.sendHeartbeat(event: client.consumePreviousCrash() == nil ? .start : .forceKill)
            await MainActor.run {
                scheduleTimers()
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
        menu.addItem(NSMenuItem(title: "Send Screenshot Now", action: #selector(sendScreenshotNow), keyEquivalent: "s"))
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
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(client.config.heartbeatActiveSeconds), repeats: true) { [weak self] _ in
            Task { await self?.client.sendHeartbeat(event: self?.client.isIdle == true ? .idle : .heartbeat) }
        }
        commandTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.client.pollCommands() }
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
        let alert = NSAlert()
        alert.messageText = "Bind this Mac"
        alert.informativeText = "Open the dashboard and enter this fingerprint:\n\n\(client.identity.fingerprint)\n\nURI:\nbigdaddy://bind?fingerprint=\(client.identity.fingerprint)"
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(client.identity.fingerprint, forType: .string)
        }
    }

    @objc private func sendScreenshotNow() {
        Task { await client.captureAndSendScreenshot(reason: "manual") }
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
        if client.verifyExitPassword(input.stringValue) {
            client.sendShutdownSync()
            NSApp.terminate(nil)
        }
    }

    private func installSignalHandlers() {
        signal(SIGTERM) { _ in BigDaddyClient.sharedForceKillPing() }
        signal(SIGINT) { _ in BigDaddyClient.sharedForceKillPing() }
        signal(SIGHUP) { _ in BigDaddyClient.sharedForceKillPing() }
    }
}
