import AppKit
import Sparkle
import WebKit

@MainActor
final class UpdateUserDriver: SPUStandardUserDriver, NSWindowDelegate, WKNavigationDelegate {
    private var updateItem: SUAppcastItem?
    private var updateAlert: NSAlert?
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var releaseNotesView: WKWebView?

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
                notes.load(Data(description.utf8), mimeType: "text/plain", characterEncodingName: "utf-8",
                           baseURL: appcastItem.releaseNotesURL ?? URL(fileURLWithPath: "/"))
            } else {
                notes.loadHTMLString(description, baseURL: appcastItem.releaseNotesURL)
            }
        } else if appcastItem.releaseNotesURL != nil {
            _ = addReleaseNotes(to: alert)
        }
        present(alert, reply: reply)
    }

    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        releaseNotesView?.load(downloadData.data, mimeType: downloadData.mimeType ?? "text/html",
                               characterEncodingName: downloadData.textEncodingName ?? "utf-8",
                               baseURL: downloadData.url)
    }

    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        releaseNotesView?.load(Data(error.localizedDescription.utf8), mimeType: "text/plain",
                               characterEncodingName: "utf-8", baseURL: URL(fileURLWithPath: "/"))
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
        content.spacing = 12
        content.setFrameSize(NSSize(width: max(360, versions.fittingSize.width), height: versions.fittingSize.height))
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
        let notes = WKWebView(frame: NSRect(x: 0, y: 0, width: content.frame.width, height: 180))
        notes.navigationDelegate = self
        content.addArrangedSubview(notes)
        notes.widthAnchor.constraint(equalToConstant: content.frame.width).isActive = true
        notes.heightAnchor.constraint(equalToConstant: 180).isActive = true
        content.setFrameSize(NSSize(width: content.frame.width, height: content.frame.height + 192))
        releaseNotesView = notes
        return notes
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
