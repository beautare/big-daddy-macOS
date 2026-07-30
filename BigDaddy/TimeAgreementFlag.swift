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
/// 只做视觉提醒，不接受点击/拖拽：`ignoresMouseEvents = true`。孩子确认剩余时间的入口是
/// 菜单栏图标本身（点开菜单能看到一条剩余时间项，见 AppDelegate.rebuildMenu），不是这面
/// 旗帜——旗帜多做一层"点掉提前收起"的交互目前没有被明确要求，先不做，减少这一版的
/// 状态机复杂度。
@MainActor
final class TimeAgreementFlag {
    private var panel: NSPanel?
    private var remainingLabel: NSTextField?
    private var noteLabel: NSTextField?

    private var dismissTimer: Timer?
    private var flashTimer: Timer?

    private static let panelSize = NSSize(width: 260, height: 68)
    private static let cornerRadius: CGFloat = 14
    private static let gapBelowStatusItem: CGFloat = 6

    // MARK: - 公开接口

    /// 每次可见期间调用，只刷新文案，不改变可见性/位置。
    func update(remainingSeconds: Int, note: String?) {
        remainingLabel?.stringValue = Self.formatClock(remainingSeconds)
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        noteLabel?.stringValue = trimmedNote
        noteLabel?.isHidden = trimmedNote.isEmpty
    }

    /// 下拉展示。`autoDismissAfter` 为 nil 表示常驻不收回（剩余 30 秒内的 sticky 态）。
    /// 若面板已经可见（同一次里程碑内被连续调用，或 sticky 态每秒被刷新文案），只更新
    /// 文案与自动收回定时器，不重复播放滑入动画。
    func present(anchor: NSStatusItem, remainingSeconds: Int, note: String?, autoDismissAfter: TimeInterval?) {
        stopFlashing()
        let panel = ensurePanel()
        update(remainingSeconds: remainingSeconds, note: note)

        let targetFrame = computeFrame(anchor: anchor)
        if panel.isVisible {
            panel.setFrame(targetFrame, display: true)
        } else {
            presentWithSlideAnimation(panel: panel, targetFrame: targetFrame)
        }
        scheduleAutoDismiss(after: autoDismissAfter)
    }

    /// 收回（滑出屏幕上方后隐藏）。对未展示的面板调用是安全的空操作。
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        stopFlashing()
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

    /// 归零后开始闪烁提醒；持续 `duration` 后自动停止闪烁并收回。
    ///
    /// `NSWorkspace.accessibilityDisplayShouldReduceMotion` 为真时不做连续闪烁（对光敏性
    /// 癫痫有实际风险，且使用者是孩子），改成两次温和的透明度呼吸。
    func startFlashing(duration: TimeInterval) {
        guard let panel, panel.isVisible else { return }
        dismissTimer?.invalidate()
        flashTimer?.invalidate()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            performGentleBreathing(times: 2)
        } else {
            var showingFull = true
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.panel else { return }
                    showingFull.toggle()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.25
                        panel.animator().alphaValue = showingFull ? 1.0 : 0.55
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            flashTimer = timer
        }

        let timeout = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopFlashingAndDismiss() }
        }
        RunLoop.main.add(timeout, forMode: .common)
        dismissTimer = timeout
    }

    func stopFlashingAndDismiss() {
        stopFlashing()
        dismiss()
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        panel?.alphaValue = 1
    }

    private func performGentleBreathing(times: Int, dimmed: Bool = true, completion: (() -> Void)? = nil) {
        guard let panel, times > 0 else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = dimmed ? 0.6 : 1.0
        }, completionHandler: { [weak self] in
            // completionHandler 是普通闭包，编译器无法从类型上证明它跑在主线程/主 actor
            // 上（即便 AppKit 动画完成回调实际上总在主线程触发）；包一层 Task { @MainActor }
            // 是本文件之外（AppDelegate 的 NSWorkspace 通知回调）已经在用的标准写法。
            Task { @MainActor [weak self] in
                self?.performGentleBreathing(times: dimmed ? times : times - 1, dimmed: !dimmed, completion: completion)
            }
        })
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

    // MARK: - 面板构建与定位

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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

    private func buildContentView() -> NSView {
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let remaining = NSTextField(labelWithString: "0:00")
        remaining.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        remaining.textColor = .labelColor
        remaining.alignment = .left
        remaining.translatesAutoresizingMaskIntoConstraints = false
        self.remainingLabel = remaining

        let note = NSTextField(labelWithString: "")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.translatesAutoresizingMaskIntoConstraints = false
        note.isHidden = true
        self.noteLabel = note

        let textStack = NSStackView(views: [remaining, note])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

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
    }

    /// 计算面板应处的屏幕坐标。三个兜底场景（对应 anchorScreenAndButtonFrame 的注释）
    /// 统一退化成"目标屏幕顶部居中"，不单独分支处理，让这里始终只有一条定位路径。
    private func computeFrame(anchor: NSStatusItem) -> NSRect {
        let size = Self.panelSize
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
