import AppKit

/// 自绘的盾牌图标：轮廓内部是 2×2 棋盘格，替代系统 SF Symbol 的纯轮廓 shield，
/// 用于菜单栏各状态和各处弹窗图标。系统 SF Symbols 里没有棋盘格盾牌这个图形，
/// 用 Bezier 路径手绘 + 裁剪填充实现，可以在任意尺寸下重新栅格化，不依赖位图资源。
enum ShieldIcon {
    private static let aspectRatio: CGFloat = 400.0 / 340.0 // 高/宽

    /// 菜单栏图标的四种状态。
    ///
    /// **盾牌本身在任何状态下都保持满尺寸、内胆不变**，状态由右侧一个独立符号承担。
    /// 这样"这是 BigDaddy"和"它现在什么状态"是两条各自完整、可以分开读的信息。
    ///
    /// 走过的三条弯路，都值得记下来免得再走一遍：
    ///
    /// 1. **换系统符号**（最初的做法）：截图开=eye、缺权限=exclamationmark.triangle、
    ///    正在截图=camera，盾牌只在默认态出现。三个符号彼此、和盾牌之间都没有形状关联，
    ///    家长看到菜单栏冒出个三角感叹号，只会以为系统坏了，根本想不到那是 BigDaddy。
    ///
    /// 2. **改盾牌内胆**（第二版）：整面填实=截图开、空心加感叹号=缺权限。轮廓是统一了，
    ///    但棋盘格——品牌标记本身——在这两个状态里被牺牲掉了，剩下一个纯色盾牌形状。
    ///
    /// 3. **右下角压徽章**（考虑过，实测否决）：在 16pt 里徽章要和盾牌分离就得挖一圈透明
    ///    护城河，护城河会把盾牌右下角啃掉一块，轮廓直接不成立；不挖护城河则两者糊成一团。
    ///    退而缩小盾牌给徽章腾位置，等于牺牲最该保住的东西——盾牌缩到 11pt 后棋盘格就开始
    ///    糊了。根因是**菜单栏里高度稀缺、宽度便宜**：叠加是在拿高度换空间，只能一起变小；
    ///    并排是拿宽度换，两个元素都能保持满尺寸。所以选了并排。
    ///
    /// 4. **并排但留出间隙**（第三版，即 gap 为正的最初实现）：两个图形各自独立、界限
    ///    清楚，但代价是看起来像"凑巧挨着的两个图标"而不是"一个整体"——家长第一眼
    ///    不容易读出它们是同一件事的两个方面。收紧成负值间距（symbolRect 的起点比盾牌
    ///    的右边界更靠左，见 image(pointSize:variant:) 里的 gap 常量），让盾牌的右下
    ///    弧线咬进符号左侧一小块，两个图形从"挨着"变成"长在一起"，读成一体。咬太深会
    ///    啃掉符号自身的可辨认轮廓（比如眼睛的杏仁尖角、三角的左下角），实测 -0.12 是
    ///    咬得出来、又不伤符号本身识别度的临界点附近，留了一点余量。
    ///
    /// 符号本身也构成一个小家族：看=空心眼睛，此刻拍下=实心眼睛，出问题=三角感叹号。
    /// 空心/实心表示"在看 / 正在拍"，和盾牌自身的视觉语言一致。
    enum Variant {
        /// 已守护、未开启截图：只有盾牌，不带任何符号
        case brand
        /// 截图已开启：盾牌 + 空心眼睛
        case watching
        /// 此刻正在截图：盾牌 + 实心眼睛（同一只眼的瞬时强化）
        case capturing
        /// 缺少系统权限：盾牌 + 三角感叹号
        case warning
    }

    /// 盾牌与状态符号的重叠量：负值 = 符号的起点比盾牌的右边界更靠左，两个图形的
    /// 包围盒相交。选负值、且盾牌后画（见下方 image 里的绘制顺序），是让两个图形
    /// 读成"一体"的关键——原因见 Variant 文档的第 4 条弯路记录。
    private static let symbolOverlapRatio: CGFloat = -0.12

    /// - Parameter pointSize: 盾牌的宽度。带符号的状态整体会更宽（菜单栏用的是
    ///   `NSStatusItem.variableLength`，宽度随状态变化本来就是支持的）。
    static func image(pointSize: CGFloat, variant: Variant = .brand) -> NSImage {
        let shieldBox = NSSize(width: pointSize, height: pointSize * aspectRatio)
        let symbolSize = variant == .brand ? 0 : pointSize * 0.62
        let gap = variant == .brand ? 0 : pointSize * symbolOverlapRatio
        let size = NSSize(width: shieldBox.width + gap + symbolSize, height: shieldBox.height)

        let image = NSImage(size: size)
        image.lockFocus()

        let inset = pointSize * 0.06
        let shieldRect = NSRect(origin: .zero, size: shieldBox).insetBy(dx: inset, dy: inset)

        // 符号先画、盾牌后画：两者的黑色区域在模板图里就是同一种"不透明"，画的先后
        // 顺序本身不改变颜色，但盾牌的棋盘格有两个格子是透明的（见 drawBrandShield）——
        // 后画的盾牌能让它自己的透明格子露出底下符号的痕迹，而不透明的格子/描边线会
        // 盖住重叠处的符号，视觉上就是"盾牌咬进符号一口"。反过来画（盾牌先、符号后）
        // 会变成符号盖住盾牌，读成"符号啃了盾牌一口"，不是我们想要的方向。
        if variant != .brand {
            let symbolRect = NSRect(x: shieldBox.width + gap, y: (size.height - symbolSize) / 2,
                                    width: symbolSize, height: symbolSize)
            switch variant {
            case .brand: break
            case .watching: drawEye(in: symbolRect, filled: false)
            case .capturing: drawEye(in: symbolRect, filled: true)
            case .warning: drawWarningTriangle(in: symbolRect)
            }
        }

        drawBrandShield(in: shieldRect, lineWidth: pointSize * 0.09)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - 组件

    private static func drawBrandShield(in rect: NSRect, lineWidth: CGFloat) {
        let shield = path(in: rect)

        NSGraphicsContext.saveGraphicsState()
        shield.addClip()
        let gridCount = 2
        let cellW = rect.width / CGFloat(gridCount)
        let cellH = rect.height / CGFloat(gridCount)
        NSColor.black.setFill()
        for row in 0..<gridCount {
            for col in 0..<gridCount where (row + col) % 2 == 0 {
                NSRect(x: rect.minX + CGFloat(col) * cellW, y: rect.minY + CGFloat(row) * cellH,
                       width: cellW, height: cellH).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.setStroke()
        shield.lineWidth = lineWidth
        shield.stroke()
    }

    /// 杏仁形眼睛。filled=false 是描边+瞳孔（"家长能看到这台机器"），filled=true 整只填实
    /// 再挖出瞳孔（"此刻正拍下一张"）——同一个形状的轻重两态，比换个符号更容易读成一件事。
    private static func drawEye(in r: NSRect, filled: Bool) {
        let w = r.width, h = r.height
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: r.minX, y: r.midY))
        eye.curve(to: NSPoint(x: r.maxX, y: r.midY),
                  controlPoint1: NSPoint(x: r.minX + 0.28 * w, y: r.minY + 1.05 * h),
                  controlPoint2: NSPoint(x: r.maxX - 0.28 * w, y: r.minY + 1.05 * h))
        eye.curve(to: NSPoint(x: r.minX, y: r.midY),
                  controlPoint1: NSPoint(x: r.maxX - 0.28 * w, y: r.maxY - 1.05 * h),
                  controlPoint2: NSPoint(x: r.minX + 0.28 * w, y: r.maxY - 1.05 * h))
        eye.close()

        // 两态的瞳孔比例不同，是实测扫出来的：描边态瞳孔是**实心**的，画大点才看得见；
        // 实心态瞳孔是**挖空**的，同样大小会把杏仁形连同它的尖角一起吃掉，读出来是个
        // 甜甜圈而不是眼睛。0.12 是尖角还在、瞳孔又认得出的那个点。
        let pupilR = w * (filled ? 0.12 : 0.17)
        let pupil = NSRect(x: r.midX - pupilR, y: r.midY - pupilR, width: pupilR * 2, height: pupilR * 2)

        if filled {
            NSColor.black.setFill()
            eye.fill()
            // 模板图只认 alpha，瞳孔必须真的挖空成透明——画白色在深色菜单栏里会被重新着色
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: pupil).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.black.setStroke()
            eye.lineWidth = max(0.7, w * 0.13)
            eye.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: pupil).fill()
        }
    }

    /// 三角感叹号。用最通用的警示符号，家长不需要学就知道"这儿有事要处理"。
    private static func drawWarningTriangle(in r: NSRect) {
        let w = r.width, h = r.height
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: r.midX, y: r.maxY))
        tri.line(to: NSPoint(x: r.maxX, y: r.minY))
        tri.line(to: NSPoint(x: r.minX, y: r.minY))
        tri.close()
        tri.lineJoinStyle = .round
        NSColor.black.setStroke()
        tri.lineWidth = max(0.7, w * 0.13)
        tri.stroke()

        NSColor.black.setFill()
        let barW = w * 0.12
        NSBezierPath(roundedRect: NSRect(x: r.midX - barW / 2, y: r.minY + 0.36 * h, width: barW, height: 0.32 * h),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        let dotD = w * 0.14
        NSBezierPath(ovalIn: NSRect(x: r.midX - dotD / 2, y: r.minY + 0.20 * h, width: dotD, height: dotD)).fill()
    }

    private static func path(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height
        let x0 = rect.minX, y0 = rect.minY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0 + 0.16 * w, y: y0 + 1.0 * h))
        path.line(to: NSPoint(x: x0 + 0.84 * w, y: y0 + 1.0 * h))
        path.curve(to: NSPoint(x: x0 + 1.0 * w, y: y0 + 0.68 * h),
                   controlPoint1: NSPoint(x: x0 + 0.96 * w, y: y0 + 1.0 * h),
                   controlPoint2: NSPoint(x: x0 + 1.0 * w, y: y0 + 0.86 * h))
        path.curve(to: NSPoint(x: x0 + 0.5 * w, y: y0),
                   controlPoint1: NSPoint(x: x0 + 1.0 * w, y: y0 + 0.32 * h),
                   controlPoint2: NSPoint(x: x0 + 0.85 * w, y: y0 + 0.12 * h))
        path.curve(to: NSPoint(x: x0, y: y0 + 0.68 * h),
                   controlPoint1: NSPoint(x: x0 + 0.15 * w, y: y0 + 0.12 * h),
                   controlPoint2: NSPoint(x: x0, y: y0 + 0.32 * h))
        path.curve(to: NSPoint(x: x0 + 0.16 * w, y: y0 + 1.0 * h),
                   controlPoint1: NSPoint(x: x0, y: y0 + 0.86 * h),
                   controlPoint2: NSPoint(x: x0 + 0.04 * w, y: y0 + 1.0 * h))
        path.close()
        return path
    }
}
