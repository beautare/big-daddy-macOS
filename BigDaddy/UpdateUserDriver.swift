import AppKit
import Sparkle
import WebKit

@MainActor
final class UpdateUserDriver: SPUStandardUserDriver, NSWindowDelegate, WKNavigationDelegate {
    private var updateItem: SUAppcastItem?
    private var updateAlert: NSAlert?
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var releaseNotesView: WKWebView?
    private var releaseNotesHeight: NSLayoutConstraint?
    private weak var releaseNotesAlert: NSAlert?

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateItem = appcastItem
        let ready = state.stage != .notDownloaded
        let alert = Self.makeUpdateAlert(currentVersion: AppVersion.current,
                                        newVersion: appcastItem.displayVersionString, ready: ready)
        if appcastItem.isCriticalUpdate {
            alert.messageText = Localization.string(zh: "重要更新", en: "Important Update")
            if !appcastItem.isMajorUpgrade {
                alert.buttons[1].isHidden = true
            }
        }
        if appcastItem.isInformationOnlyUpdate {
            alert.buttons[0].title = Localization.string(zh: "了解详情", en: "Learn More")
            alert.informativeText = Localization.string(zh: "在网页上查看此更新的详情。", en: "View details about this update on the web.")
        }
        if !appcastItem.isCriticalUpdate || appcastItem.isMajorUpgrade {
            alert.addButton(withTitle: Localization.string(zh: "跳过此版本", en: "Skip This Version"))
                .tag = SPUUserUpdateChoice.skip.rawValue
        }

        if let description = appcastItem.itemDescription, !description.isEmpty {
            let notes = addReleaseNotes(to: alert)
            if appcastItem.itemDescriptionFormat == "plain-text" || appcastItem.itemDescriptionFormat == "markdown" {
                notes.loadHTMLString(Self.styledHTML(Self.preformatted(description)), baseURL: appcastItem.releaseNotesURL)
            } else {
                notes.loadHTMLString(Self.styledHTML(description), baseURL: appcastItem.releaseNotesURL)
            }
        } else if appcastItem.releaseNotesURL != nil {
            _ = addReleaseNotes(to: alert)
        }
        present(alert, reply: reply)
    }

    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let text = String(decoding: downloadData.data, as: UTF8.self)
        let body = (downloadData.mimeType ?? "text/html").contains("html") ? text : Self.preformatted(text)
        releaseNotesView?.loadHTMLString(Self.styledHTML(body), baseURL: downloadData.url)
    }

    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        releaseNotesView?.loadHTMLString(Self.styledHTML(Self.preformatted(error.localizedDescription)),
                                         baseURL: URL(fileURLWithPath: "/"))
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 同一次更新从发现、下载到准备安装始终使用同一个更新条目。
        let alert = Self.makeUpdateAlert(currentVersion: AppVersion.current,
                                        newVersion: updateItem!.displayVersionString, ready: true)
        present(alert, reply: reply)
    }

    static func makeUpdateAlert(currentVersion: String, newVersion: String, ready: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = Localization.string(zh: "发现新版本", en: "A New Version Is Available")
        alert.informativeText = ready
            ? Localization.string(zh: "更新已就绪，安装后将重启 BigDaddy。", en: "The update is ready. Installing will restart BigDaddy.")
            : Localization.string(zh: "是否下载并安装此更新？", en: "Would you like to download and install this update?")
        let versions = NSTextField(labelWithAttributedString: AppDelegate.makeVersionTransitionAttributedString(
            currentVersion: currentVersion, newVersion: newVersion, ready: ready
        ))
        let content = NSStackView(views: [versions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.setFrameSize(NSSize(width: max(400, versions.fittingSize.width), height: versions.fittingSize.height))
        alert.accessoryView = content
        alert.addButton(withTitle: ready
            ? Localization.string(zh: "安装并重启", en: "Install & Restart")
            : Localization.string(zh: "下载并安装", en: "Download & Install"))
            .tag = SPUUserUpdateChoice.install.rawValue
        alert.addButton(withTitle: Localization.string(zh: "稍后", en: "Later"))
            .tag = SPUUserUpdateChoice.dismiss.rawValue
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert
    }

    private func addReleaseNotes(to alert: NSAlert) -> WKWebView {
        let content = alert.accessoryView as! NSStackView
        let width = content.frame.width
        let initialHeight: CGFloat = 120

        let notes = WKWebView(frame: .zero)
        notes.navigationDelegate = self
        notes.setValue(false, forKey: "drawsBackground")
        notes.translatesAutoresizingMaskIntoConstraints = false

        let card = ReleaseNotesCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(notes)
        NSLayoutConstraint.activate([
            notes.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            notes.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            notes.topAnchor.constraint(equalTo: card.topAnchor),
            notes.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.widthAnchor.constraint(equalToConstant: width)
        ])
        let height = card.heightAnchor.constraint(equalToConstant: initialHeight)
        height.isActive = true
        content.addArrangedSubview(card)
        content.setFrameSize(NSSize(width: width, height: content.frame.height + initialHeight + content.spacing))

        releaseNotesView = notes
        releaseNotesHeight = height
        releaseNotesAlert = alert
        return notes
    }

    private static func preformatted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre>\(escaped)</pre>"
    }

    private static func styledHTML(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; }
        html, body { background: transparent; }
        body { margin: 0; padding: 12px 14px; font: 13px/1.55 -apple-system, "PingFang SC", sans-serif;
               color: CanvasText; word-wrap: break-word; }
        h1, h2, h3 { font-size: 14px; margin: 0 0 6px; }
        p, ul, ol { margin: 0 0 8px; } ul, ol { padding-left: 20px; }
        a { color: LinkText; text-decoration: none; font-weight: 500; }
        a:hover { text-decoration: underline; }
        pre { margin: 0; white-space: pre-wrap; font: inherit; }
        </style></head><body>\(body)</body></html>
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
            guard let self, let measured = result as? CGFloat, let constraint = self.releaseNotesHeight,
                  let alert = self.releaseNotesAlert, let content = alert.accessoryView as? NSStackView else { return }
            let target = min(max(measured, 44), 220)
            let delta = target - constraint.constant
            guard delta != 0 else { return }
            constraint.constant = target
            content.setFrameSize(NSSize(width: content.frame.width, height: content.frame.height + delta))
            alert.layout()
            alert.window.center()
        }
    }

    private func present(_ alert: NSAlert, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.dismissUpdateInstallation()
        updateAlert?.window.delegate = nil
        updateAlert?.window.close()
        updateAlert = alert
        updateReply = reply
        for button in alert.buttons {
            button.target = self
            button.action = #selector(updateActionTapped(_:))
        }
        alert.layout()
        alert.window.delegate = self
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func updateActionTapped(_ sender: NSButton) {
        let choice = SPUUserUpdateChoice(rawValue: sender.tag)!
        if choice == .install, let item = updateItem, item.isInformationOnlyUpdate {
            NSWorkspace.shared.open(item.infoURL!)
            finish(.dismiss)
        } else {
            finish(choice)
        }
    }

    private func finish(_ choice: SPUUserUpdateChoice) {
        let reply = updateReply
        updateReply = nil
        updateAlert?.window.delegate = nil
        updateAlert?.window.close()
        updateAlert = nil
        releaseNotesView = nil
        releaseNotesHeight = nil
        reply?(choice)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === updateAlert?.window {
            finish(.dismiss)
        }
    }

    override func showUpdateInFocus() {
        if let alert = updateAlert {
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
        } else {
            super.showUpdateInFocus()
        }
    }

    override func dismissUpdateInstallation() {
        updateReply = nil
        updateAlert?.window.delegate = nil
        updateAlert?.window.close()
        updateAlert = nil
        releaseNotesView = nil
        updateItem = nil
        super.dismissUpdateInstallation()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

private final class ReleaseNotesCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
