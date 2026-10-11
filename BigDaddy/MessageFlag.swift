import AppKit
import QuartzCore

/// 能成为 key window 的无边框面板。默认的 borderless NSPanel 拿不到键盘焦点，
/// 孩子点「回复」之后就没法打字。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 家长消息的下拉旗帜：从菜单栏图标下方滑出，与时间约定旗帜同一套视觉语言，但用蓝色
/// 而不是琥珀色，一眼区分"家长说了一句话"和"时间到了"。
///
/// 两种形态：
/// - **家长消息**：常驻，直到孩子点「知道了」或回复完——这是家长主动要孩子看到的一句话，
///   不该自己悄悄消失；面板很小、不抢焦点，挂着不影响孩子继续做事。
/// - **通知**（例如"这次没有同意你的申请"）：纯展示，对鼠标透明，几秒后自动收回。
///
/// 和 TimeAgreementFlag 一样用 `.nonactivatingPanel`：出现时**不抢键盘焦点**，孩子正在
/// 打的字不会被打断。只有孩子主动点了「回复」，面板才 makeKey 拿焦点。
///
/// 只在一块屏幕上展示（菜单栏图标所在的那块）：回复需要一个确定的输入框，多屏各放一份
/// 会让焦点和输入状态分裂。
@MainActor
final class MessageFlag: NSObject, NSTextFieldDelegate {
    /// 孩子点了「知道了」：收起面板 + 把这些家长消息标成已读
    var onAcknowledge: (() -> Void)?
    /// 发送一条回复。返回 nil 表示成功，否则是给孩子看的错误文案。
    var onSend: ((String) async -> String?)?
    /// 点了"查看全部"
    var onOpenHistory: (() -> Void)?

    /// 当前展示中的家长消息 id（通知形态时为 nil）
    private(set) var shownMessageId: String?
    var isVisible: Bool { panel?.isVisible == true }

    private static let panelWidth: CGFloat = 320
    private static let padding: CGFloat = 14
    private static let cornerRadius: CGFloat = 14
    private static let gapBelowAnchor: CGFloat = 6
    private static let accentColor = NSColor.systemBlue

    private var panel: KeyablePanel?
    private var column: NSStackView!
    private var iconView: NSImageView!
    private var captionLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var moreButton: NSButton!
    private var replyArea: NSStackView!
    private var replyField: NSTextField!
    private var replyHintLabel: NSTextField!
    private var errorLabel: NSTextField!
    private var replyButton: NSButton!
    private var ackButton: NSButton!
    private var cancelButton: NSButton!
    private var sendButton: NSButton!
    private var quickReplyButtons: [NSButton] = []
    private var dismissTimer: Timer?
    private var isReplying = false
    /// 当前这条家长消息是否还允许回复（回复窗口、次数由服务端判定）
    private var canReply = false
    private var isSending = false
    private weak var anchor: NSStatusItem?
    private weak var avoiding: TimeAgreementFlag?

    // MARK: - 公开接口

    /// 展示一条家长消息。同一条消息已经在屏幕上时只刷新文案，不重复滑入。
    func presentParentMessage(
        _ message: ChatMessage, moreUnread: Int, canReply: Bool, replyHint: String?,
        anchor: NSStatusItem, avoiding: TimeAgreementFlag?
    ) {
        buildIfNeeded()
        self.anchor = anchor
        self.avoiding = avoiding
        dismissTimer?.invalidate()
        dismissTimer = nil
        let alreadyShowing = isVisible && shownMessageId == message.id
        shownMessageId = message.id

        iconView.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)
        iconView.contentTintColor = Self.accentColor
        captionLabel.stringValue = Localization.string(zh: "家长发来消息", en: "From your parent")
            + " · " + ChatText.clock(message.sentDate)
        captionLabel.textColor = .secondaryLabelColor
        bodyLabel.stringValue = message.text ?? ""
        moreButton.title = moreUnread > 0
            ? Localization.string(zh: "还有 \(moreUnread) 条未读 · 查看全部", en: "\(moreUnread) more unread · View all")
            : Localization.string(zh: "查看全部消息", en: "View all messages")
        moreButton.isHidden = false
        self.canReply = canReply
        replyButton.isHidden = !canReply
        replyHintLabel.stringValue = replyHint ?? ""
        ackButton.isHidden = false
        panel?.ignoresMouseEvents = false
        if !alreadyShowing {
            setReplying(false)
        }
        show(animated: !alreadyShowing)
    }

    /// 一条短暂的通知（例如申请的结果）。对鼠标透明，`duration` 秒后自动收回。
    func presentNotice(title: String, body: String, symbol: String, tint: NSColor,
                       anchor: NSStatusItem, avoiding: TimeAgreementFlag?, duration: TimeInterval = 6) {
        // 孩子正在回一条家长消息时，不拿通知把他的输入框顶掉
        if isVisible && (isReplying || shownMessageId != nil) { return }
        buildIfNeeded()
        self.anchor = anchor
        self.avoiding = avoiding
        shownMessageId = nil
        canReply = false
        setReplying(false)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = tint
        captionLabel.stringValue = title
        captionLabel.textColor = tint
        bodyLabel.stringValue = body
        moreButton.isHidden = true
        replyButton.isHidden = true
        ackButton.isHidden = true
        panel?.ignoresMouseEvents = true
        show(animated: true)
        scheduleDismiss(after: duration)
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        shownMessageId = nil
        isReplying = false
        guard let panel, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        } else {
            var end = panel.frame
            end.origin.y += end.height
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(end, display: true)
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }

    // MARK: - 交互

    @objc private func replyTapped() {
        setReplying(true)
        relayout()
        // 只有在孩子主动要回复时才拿键盘焦点
        panel?.makeKey()
        panel?.makeFirstResponder(replyField)
    }

    @objc private func cancelTapped() {
        setReplying(false)
        relayout()
        panel?.resignKey()
    }

    @objc private func ackTapped() {
        onAcknowledge?()
        dismiss()
    }

    @objc private func moreTapped() {
        onOpenHistory?()
    }

    @objc private func sendTapped() {
        send(replyField.stringValue)
    }

    @objc private func quickReplyTapped(_ sender: NSButton) {
        send(sender.title)
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let onSend else { return }
        isSending = true
        setControlsEnabled(false)
        errorLabel.isHidden = true
        Task { @MainActor [weak self] in
            let error = await onSend(text)
            guard let self else { return }
            self.isSending = false
            self.setControlsEnabled(true)
            if let error {
                self.errorLabel.stringValue = error
                self.errorLabel.isHidden = false
                self.relayout()
                return
            }
            self.replyField.stringValue = ""
            self.captionLabel.stringValue = Localization.string(zh: "已发送 ✓", en: "Sent ✓")
            self.captionLabel.textColor = .systemGreen
            self.setReplying(false)
            self.replyButton.isHidden = true
            self.ackButton.isHidden = true
            self.moreButton.isHidden = true
            self.relayout()
            self.panel?.resignKey()
            self.scheduleDismiss(after: 1.2)
        }
    }

    /// Esc 取消回复；回车由 NSTextField 的 action 触发发送。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTapped()
            return true
        }
        return false
    }

    private func setReplying(_ replying: Bool) {
        isReplying = replying
        replyArea.isHidden = !replying
        errorLabel.isHidden = true
        replyButton.isHidden = replying || !canReply
        ackButton.isHidden = replying || shownMessageId == nil
        cancelButton.isHidden = !replying
        sendButton.isHidden = !replying
        if replying {
            dismissTimer?.invalidate()
            dismissTimer = nil
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        replyField.isEnabled = enabled
        sendButton.isEnabled = enabled
        cancelButton.isEnabled = enabled
        quickReplyButtons.forEach { $0.isEnabled = enabled }
    }

    private func scheduleDismiss(after interval: TimeInterval) {
        dismissTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    // MARK: - 布局

    private func show(animated: Bool) {
        guard let panel else { return }
        let target = targetFrame()
        if panel.isVisible || !animated {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            var start = target
            start.origin.y += target.height
            panel.alphaValue = 1
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
        panel.invalidateShadow()
    }

    /// 内容高度变了（展开回复区、出现错误提示）：保持顶边不动，向下伸缩。
    private func relayout() {
        guard let panel, panel.isVisible else { return }
        let size = contentSize()
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow()
    }

    private func contentSize() -> NSSize {
        column.layoutSubtreeIfNeeded()
        return NSSize(width: Self.panelWidth, height: column.fittingSize.height + Self.padding * 2)
    }

    private func targetFrame() -> NSRect {
        let size = contentSize()
        let screen = anchor?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first!
        var origin: NSPoint
        if let anchor, let button = TimeAgreementFlag.anchorButtonFrame(anchor: anchor, on: screen) {
            origin = NSPoint(x: button.midX - size.width / 2, y: button.minY - size.height - Self.gapBelowAnchor)
        } else {
            origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.frame.maxY - screen.safeAreaInsets.top - size.height - 8
            )
        }
        // 时间约定旗帜正挂着时排到它下面，不叠在一起
        if let timeFrame = avoiding?.visiblePanelFrame(on: screen) {
            origin.y = min(origin.y, timeFrame.minY - 8 - size.height)
        }
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
        origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        return NSRect(origin: origin, size: size)
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        // 圆角走 maskImage 而不是 layer.cornerRadius，理由见 TimeAgreementFlag.buildContentView
        container.maskImage = TimeAgreementFlag.roundedMaskImage(cornerRadius: Self.cornerRadius)
        container.autoresizingMask = [.width, .height]

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Self.accentColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        captionLabel = NSTextField(labelWithString: "")
        captionLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let header = NSStackView(views: [iconView, captionLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let innerWidth = Self.panelWidth - Self.padding * 2
        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = NSFont.systemFont(ofSize: 14)
        bodyLabel.textColor = .labelColor
        bodyLabel.preferredMaxLayoutWidth = innerWidth
        bodyLabel.isSelectable = false

        moreButton = NSButton(title: "", target: self, action: #selector(moreTapped))
        moreButton.isBordered = false
        moreButton.contentTintColor = Self.accentColor
        moreButton.font = NSFont.systemFont(ofSize: 11)

        // 回复区：常用语 + 输入框 + 剩余次数提示
        quickReplyButtons = ChatText.quickReplies.map { phrase in
            let button = NSButton(title: phrase, target: self, action: #selector(quickReplyTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            return button
        }
        let quickRow1 = NSStackView(views: Array(quickReplyButtons.prefix(2)))
        let quickRow2 = NSStackView(views: Array(quickReplyButtons.dropFirst(2)))
        for row in [quickRow1, quickRow2] {
            row.orientation = .horizontal
            row.spacing = 6
        }
        replyField = NSTextField(string: "")
        replyField.placeholderString = Localization.string(zh: "写一句回复…", en: "Write a reply…")
        replyField.delegate = self
        replyField.target = self
        replyField.action = #selector(sendTapped)
        replyField.translatesAutoresizingMaskIntoConstraints = false
        replyHintLabel = NSTextField(labelWithString: "")
        replyHintLabel.font = NSFont.systemFont(ofSize: 10)
        replyHintLabel.textColor = .tertiaryLabelColor
        replyArea = NSStackView(views: [quickRow1, quickRow2, replyField, replyHintLabel])
        replyArea.orientation = .vertical
        replyArea.alignment = .leading
        replyArea.spacing = 6
        replyArea.isHidden = true

        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = innerWidth
        errorLabel.isHidden = true

        replyButton = NSButton(title: Localization.string(zh: "回复", en: "Reply"), target: self, action: #selector(replyTapped))
        replyButton.bezelStyle = .rounded
        ackButton = NSButton(title: Localization.string(zh: "知道了", en: "Got it"), target: self, action: #selector(ackTapped))
        ackButton.bezelStyle = .rounded
        cancelButton = NSButton(title: Localization.string(zh: "取消", en: "Cancel"), target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        sendButton = NSButton(title: Localization.string(zh: "发送", en: "Send"), target: self, action: #selector(sendTapped))
        sendButton.bezelStyle = .rounded
        sendButton.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, replyButton, cancelButton, ackButton, sendButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        column = NSStackView(views: [header, bodyLabel, moreButton, replyArea, errorLabel, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        for view in [moreButton!, replyArea!, errorLabel!] as [NSView] {
            column.setVisibilityPriority(.notVisible, for: view)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 3),
            column.widthAnchor.constraint(equalToConstant: innerWidth),
            column.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
            // 标题行撑满整列：不撑的话首次展示时 NSStackView 可能把标题压成零宽
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            replyField.widthAnchor.constraint(equalToConstant: innerWidth)
        ])

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = container
        self.panel = panel
    }
}
