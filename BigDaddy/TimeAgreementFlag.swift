import AppKit
import QuartzCore

/// "时间约定"下拉旗帜：从菜单栏图标下方滑出，展示剩余时间与家长留言。
///
/// 用 NSPanel 而不是常规 NSWindow：`.borderless` + `.nonactivatingPanel` 这两个 styleMask
/// 缺一不可——不设 `.nonactivatingPanel` 时，面板一出现就会抢走键盘焦点、打断孩子正在
/// 输入的内容，这是个"提醒类"功能，不该有这种副作用。`level = .statusBar` +
/// `collectionBehavior` 里的 `.fullScreenAuxiliary` 让它在孩子当前开着某个全屏 App 时也能
/// 浮现出来，而不是被全屏空间挡住。
///
/// 两种形态：
/// - **倒计时中**：纯展示，`ignoresMouseEvents = true`，点不到也拖不动。孩子确认剩余
///   时间的入口是菜单栏图标本身（点开菜单能看到一条剩余时间项，见 AppDelegate.rebuildMenu）。
/// - **时间到**：换成琥珀色告警配色，并长出一颗「我知道了」按钮，此时才打开鼠标事件。
///   到点提醒会一直挂在屏幕上（最长 5 分钟），如果不给一个关掉它的出口，孩子就只能
///   眼睁睁看着它挡在那儿——那不是提醒，是惩罚。
@MainActor
final class TimeAgreementFlag {
    private var panel: NSPanel?
    private var contentColumn: NSStackView?
    private var captionLabel: NSTextField?
    private var remainingLabel: NSTextField?
    private var noteLabel: NSTextField?
    private var iconView: NSImageView?
    /// 到点时呼吸的那条琥珀色横杠。只让它一个人动，文字始终保持全不透明。
    private var accentBar: NSView?
    private var acknowledgeButton: NSButton?

    private var dismissTimer: Timer?
    /// 当前是否处于"时间到"形态，决定配色、按钮可见性与鼠标事件开关
    private var isExpiredState = false

    /// 孩子点了「我知道了」。由 AppDelegate 注入：收起面板 + 上报回执。
    var onAcknowledge: (() -> Void)?

    private static let panelWidth: CGFloat = 268
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 14
    private static let cornerRadius: CGFloat = 14
    private static let gapBelowStatusItem: CGFloat = 6
    private static let accentColor = NSColor.systemOrange

    // MARK: - 公开接口

    /// 每次可见期间调用，只刷新文案，不改变可见性/位置。
    func update(remainingSeconds: Int, note: String?) {
        remainingLabel?.stringValue = Self.formatClock(remainingSeconds)
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        noteLabel?.stringValue = trimmedNote
        noteLabel?.isHidden = trimmedNote.isEmpty
    }

    /// 下拉展示（倒计时形态）。`autoDismissAfter` 为 nil 表示常驻不收回（剩余 30 秒内的 sticky 态）。
    /// 若面板已经可见（同一次里程碑内被连续调用，或 sticky 态每秒被刷新文案），只更新
    /// 文案与自动收回定时器，不重复播放滑入动画。
    func present(anchor: NSStatusItem, remainingSeconds: Int, note: String?, autoDismissAfter: TimeInterval?) {
        applyExpiredState(false)
        showPanel(anchor: anchor, remainingSeconds: remainingSeconds, note: note)
        scheduleAutoDismiss(after: autoDismissAfter)
    }

    /// 倒计时归零：切到"时间到"形态并开始呼吸提醒，持续 `duration` 后自动收回。
    ///
    /// 与旧的 `startFlashing` 有两点关键差异：
    /// 1. 面板不可见时会**自己弹出来**（孩子可能刚把上一次里程碑的旗帜等到自动收回），
    ///    到点这一刻正是最不能沉默的时候；
    /// 2. 读数显式写成 0:00。此前这一步只切换动画、不刷新文案，而最后一次 tick 拿到的
    ///    剩余量经 `.rounded(.up)` 恒为 1，于是归零瞬间屏幕上冻结的是 "0:01"。
    func presentTimeUp(anchor: NSStatusItem, note: String?, duration: TimeInterval) {
        applyExpiredState(true)
        showPanel(anchor: anchor, remainingSeconds: 0, note: note)
        startAccentPulse()
        scheduleAutoDismiss(after: duration)
    }

    /// 收回（滑出屏幕上方后隐藏）。对未展示的面板调用是安全的空操作。
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        stopAccentPulse()
        guard let panel, panel.isVisible else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        } else {
            var endFrame = panel.frame
            endFrame.origin.y += endFrame.height
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(endFrame, display: true)
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }

    // MARK: - 展示与形态切换

    private func showPanel(anchor: NSStatusItem, remainingSeconds: Int, note: String?) {
        let panel = ensurePanel()
        update(remainingSeconds: remainingSeconds, note: note)

        // 内容高度随"有没有留言""是不是到点形态"变化，每次展示都按当前内容重新量一次，
        // 而不是写死一个能装下所有情况的高度——那样没有留言时下方会空出一大块。
        let targetFrame = computeFrame(anchor: anchor, size: currentContentSize())
        if panel.isVisible {
            panel.setFrame(targetFrame, display: true)
        } else {
            presentWithSlideAnimation(panel: panel, targetFrame: targetFrame)
        }
    }

    /// 按当前内容量出面板该有多高。宽度恒定，只有高度随"有没有留言""要不要显示按钮"变。
    ///
    /// 量的是竖排本身而不是容器：容器是窗口的 contentView，它的尺寸反过来由窗口 frame
    /// 决定（autoresizing），拿它测高会绕成一个循环。
    private func currentContentSize() -> NSSize {
        guard let column = contentColumn else { return NSSize(width: Self.panelWidth, height: 88) }
        column.layoutSubtreeIfNeeded()
        return NSSize(width: Self.panelWidth, height: column.fittingSize.height + Self.verticalPadding * 2)
    }

    /// 倒计时形态 ⇄ 时间到形态。两者只差配色、图标、标题与那颗按钮，共用同一套控件。
    private func applyExpiredState(_ expired: Bool) {
        _ = ensurePanel()
        isExpiredState = expired

        iconView?.image = NSImage(
            systemSymbolName: expired ? "bell.badge.fill" : "hourglass",
            accessibilityDescription: nil
        )
        iconView?.contentTintColor = expired ? Self.accentColor : .labelColor
        captionLabel?.stringValue = expired
            ? Localization.string(zh: "约定时间到了", en: "Time's up")
            : Localization.string(zh: "时间约定剩余", en: "Time left")
        captionLabel?.textColor = expired ? Self.accentColor : .secondaryLabelColor
        remainingLabel?.textColor = expired ? Self.accentColor : .labelColor
        accentBar?.isHidden = !expired
        acknowledgeButton?.isHidden = !expired
        // 倒计时形态下面板必须对鼠标透明，否则它会挡住下面窗口的点击；只有长出按钮的
        // 到点形态才需要接收事件。
        panel?.ignoresMouseEvents = !expired
        if !expired { stopAccentPulse() }
    }

    @objc private func acknowledgeTapped() {
        dismiss()
        onAcknowledge?()
    }

    // MARK: - 到点提醒的呼吸动效

    /// 只让那条琥珀色横杠呼吸，文字与读数始终全不透明。
    ///
    /// 旧实现是每 0.5 秒把**整个面板**的 alpha 在 1.0/0.55 之间来回切：读数在半透明帧里
    /// 直接糊进背景，孩子想看清"到底几点了"反而要等它闪回来；而"整块界面忽明忽暗"在
    /// 观感上更像故障而不是提醒。改用 Core Animation 的 autoreverse 循环还有一个附带
    /// 好处——不再需要一个每秒醒两次的 Timer，也不会因为忘记 invalidate 而漏动画。
    ///
    /// `accessibilityDisplayShouldReduceMotion` 为真时完全不动：使用者是孩子，闪烁对
    /// 光敏性癫痫有实际风险，而此时配色和图标的变化已经足够说明"到点了"。
    private func startAccentPulse() {
        guard let bar = accentBar, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        bar.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.2
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.layer?.add(pulse, forKey: "bigdaddy.timeup.pulse")
    }

    private func stopAccentPulse() {
        accentBar?.layer?.removeAnimation(forKey: "bigdaddy.timeup.pulse")
    }

    private func scheduleAutoDismiss(after interval: TimeInterval?) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let interval else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private static func formatClock(_ totalSeconds: Int) -> String {
        let safe = max(0, totalSeconds)
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }

    /// NSVisualEffectView 的圆角遮罩。
    ///
    /// 只画一个刚好够容纳四个圆角的小图（2r+1 边长），靠 `capInsets` + `.stretch` 把
    /// 中间那 1×1 像素拉伸到实际面板尺寸——四角保持原样不被拉变形。这样遮罩与
    /// 面板尺寸解耦，内容高度每次展示都在变也不需要重画遮罩。
    ///
    /// `NSImage(size:flipped:drawingHandler:)` 的绘制块在每次需要该图时按当时尺寸重新
    /// 执行，因此这里画的是"当前请求的 rect"而不是写死的常量。
    private static func roundedMaskImage(cornerRadius radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - 面板构建与定位

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 88),
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
        panel.ignoresMouseEvents = true
        // .fullScreenAuxiliary 让面板能与孩子当前打开的全屏 App 共存显示，而不是被全屏
        // 空间挡住；.canJoinAllSpaces + .stationary 让它不随空间切换移动、始终跟着状态栏。
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = buildContentView()

        self.panel = panel
        return panel
    }

    /// 内容整体**水平居中**。
    ///
    /// 此前是"图标 + 左对齐文字"一横排、整排靠左顶着 16pt 内边距：读数只有 "3:24" 四个
    /// 字符宽，右侧就空出一大片，看上去像排版塌了一半。现在改成竖排居中——标题、读数、
    /// 留言三行共享同一条中轴线，无论读数是 "12:00" 还是 "0:05"、有没有留言，视觉重心
    /// 都落在面板正中。
    private func buildContentView() -> NSView {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        // 圆角必须用 maskImage，不能用 layer.cornerRadius + masksToBounds。
        //
        // NSVisualEffectView 的毛玻璃是由窗口服务器在**这个视图的图层之外**合成的，
        // CALayer 的裁剪管不到它：四角会照旧露出材质的直角，而 borderless 窗口的
        // hasShadow 阴影轮廓又是按不透明区域计算的，于是尖角会在阴影上再现一次——
        // 表现就是"设了圆角但四个角仍能看到矩形尖角"。maskImage 是 AppKit 为这个视图
        // 专门提供的裁剪入口，材质与阴影都会遵循它。
        // 容器是窗口的 contentView，尺寸由窗口 frame 经 autoresizing 决定，因此这里
        // **不能**关掉 translatesAutoresizingMaskIntoConstraints——那会让它自己也去参与
        // 约束求解，和 AppKit 给 contentView 加的那套约束打架。子视图照常用约束布局。
        container.maskImage = Self.roundedMaskImage(cornerRadius: Self.cornerRadius)
        container.autoresizingMask = [.width, .height]

        // 到点时呼吸的琥珀色横杠，贴在面板顶边——位置固定、不参与竖排堆叠，
        // 因此它的显隐不会让下面三行文字跳动。
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Self.accentColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        container.addSubview(bar)
        self.accentBar = bar

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        self.iconView = icon

        let caption = NSTextField(labelWithString: Localization.string(zh: "时间约定剩余", en: "Time left"))
        caption.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        self.captionLabel = caption

        // 图标和标题同一行：图标单独占一行会把面板拉高一截，而它承载的信息量还不如
        // 标题那几个字——并排放既省高度，又让"沙漏/铃铛"这个状态提示紧贴文字含义。
        let header = NSStackView(views: [icon, caption])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let remaining = NSTextField(labelWithString: "0:00")
        // 等宽数字：不用它的话，秒数从 "1:19" 走到 "1:20" 时整行宽度会变，居中布局下
        // 读数会左右微微跳动，盯着看一分钟就很难受。
        remaining.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        remaining.textColor = .labelColor
        remaining.alignment = .center
        self.remainingLabel = remaining

        let note = NSTextField(labelWithString: "")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        // 留言最长 200 字，按固有宽度能撑到面板的好几倍。压低横向抗压缩优先级，
        // 让下面那条固定宽度的约束赢，多出来的部分老实截断成省略号。
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.noteLabel = note

        let ack = NSButton(
            title: Localization.string(zh: "我知道了", en: "Got it"),
            target: self,
            action: #selector(acknowledgeTapped)
        )
        ack.bezelStyle = .rounded
        ack.controlSize = .regular
        ack.keyEquivalent = "\r"
        ack.isHidden = true
        self.acknowledgeButton = ack

        let column = NSStackView(views: [header, remaining, note, ack])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 4
        // 隐藏的行不该继续占位：没有留言时那 11pt 的空行会让面板显得头重脚轻。
        column.setVisibilityPriority(.notVisible, for: note)
        column.setVisibilityPriority(.notVisible, for: ack)
        column.setCustomSpacing(8, after: remaining)
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),

            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 3),

            // 竖排宽度写死成"面板宽 - 两侧内边距"，而不是让内容自己撑：读数、标题、
            // 留言三者宽度差得很远，跟着内容走的话面板会随秒数增减左右呼吸。
            column.widthAnchor.constraint(equalToConstant: Self.panelWidth - Self.horizontalPadding * 2),
            column.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.verticalPadding)
        ])

        self.contentColumn = column
        return container
    }

    private func presentWithSlideAnimation(panel: NSPanel, targetFrame: NSRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.alphaValue = 0
            panel.setFrame(targetFrame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            var startFrame = targetFrame
            startFrame.origin.y += targetFrame.height
            panel.alphaValue = 1
            panel.setFrame(startFrame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        }
        // borderless 窗口的阴影是按不透明区域缓存的，而遮罩生效的时机可能晚于窗口首次
        // 上屏；不主动作废一次，第一次展示时可能留下一圈按未裁剪的直角算出来的旧阴影。
        panel.invalidateShadow()
    }

    /// 计算面板应处的屏幕坐标。三个兜底场景（对应 anchorScreenAndButtonFrame 的注释）
    /// 统一退化成"目标屏幕顶部居中"，不单独分支处理，让这里始终只有一条定位路径。
    private func computeFrame(anchor: NSStatusItem, size: NSSize) -> NSRect {
        let (screen, buttonFrameOnScreen) = Self.anchorScreenAndButtonFrame(anchor: anchor)
        guard let screen else {
            // 连一块屏幕都取不到，理论上不会发生（运行中的 macOS 系统至少有一块主屏）；
            // 给一个不越界的兜底原点，好过让整个定位链条向上传染 optional。
            return NSRect(origin: NSPoint(x: 100, y: 100), size: size)
        }
        var origin: NSPoint
        if let buttonFrameOnScreen {
            origin = NSPoint(
                x: buttonFrameOnScreen.midX - size.width / 2,
                y: buttonFrameOnScreen.minY - size.height - Self.gapBelowStatusItem
            )
        } else {
            let topInset: CGFloat
            if #available(macOS 12.0, *) {
                topInset = screen.safeAreaInsets.top
            } else {
                topInset = 0
            }
            origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.frame.maxY - topInset - size.height - 8
            )
        }
        // 钳制在目标屏幕可见范围内，避免多显示器边界情况下面板被裁到屏幕外
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
        origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        return NSRect(origin: origin, size: size)
    }

    /// 返回锚定用的屏幕与状态栏图标按钮在该屏幕上的 frame。
    ///
    /// 三种情况会拿不到可用的按钮 frame，统一返回 nil 交给调用方走"顶部居中"兜底：
    /// 1. 图标被系统折叠，或被 Bartender/Ice 一类工具隐藏——`isVisible` 为假，或即便为真，
    ///    其 window 也可能不在任何当前可见屏幕上；
    /// 2. 孩子正在使用某个全屏 App——`currentSystemPresentationOptions` 会带上
    ///    `.autoHideMenuBar`/`.hideMenuBar`，此时菜单栏本身处于隐藏/自动收起状态，图标的
    ///    几何位置没有意义；
    /// 3. screen 本身也拿不到时（图标彻底不可用），退到 NSScreen.main / 任意一块屏幕。
    private static func anchorScreenAndButtonFrame(anchor: NSStatusItem) -> (screen: NSScreen?, buttonFrame: NSRect?) {
        let menuBarHidden = NSApp.currentSystemPresentationOptions.contains(.autoHideMenuBar)
            || NSApp.currentSystemPresentationOptions.contains(.hideMenuBar)
        guard !menuBarHidden,
              anchor.isVisible,
              let button = anchor.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else {
            let fallbackScreen = anchor.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
            return (fallbackScreen, nil)
        }
        let boundsInWindow = button.convert(button.bounds, to: nil)
        let frameOnScreen = buttonWindow.convertToScreen(boundsInWindow)
        return (screen, frameOnScreen)
    }
}
