import AppKit

/// 自绘的盾牌图标：轮廓内部是 2×2 棋盘格，替代系统 SF Symbol 的纯轮廓 shield，
/// 用于菜单栏各状态和各处弹窗图标。系统 SF Symbols 里没有棋盘格盾牌这个图形，
/// 用 Bezier 路径手绘 + 裁剪填充实现，可以在任意尺寸下重新栅格化，不依赖位图资源。
enum ShieldIcon {
    private static let aspectRatio: CGFloat = 400.0 / 340.0 // 高/宽

    /// 菜单栏图标的四种状态。
    ///
    /// **盾牌本身在任何状态下都保持满尺寸、内胆不变**，状态由右下角一枚圆形徽章承担。
    /// 这样"这是 BigDaddy"和"它现在什么状态"是两条各自完整、可以分开读的信息。
    ///
    /// 走过的几条弯路，都值得记下来免得再走一遍：
    ///
    /// 1. **换系统符号**（最初的做法）：截图开=eye、缺权限=exclamationmark.triangle、
    ///    正在截图=camera，盾牌只在默认态出现。三个符号彼此、和盾牌之间都没有形状关联，
    ///    家长看到菜单栏冒出个三角感叹号，只会以为系统坏了，根本想不到那是 BigDaddy。
    ///
    /// 2. **改盾牌内胆**（第二版）：整面填实=截图开、空心加感叹号=缺权限。轮廓是统一了，
    ///    但棋盘格——品牌标记本身——在这两个状态里被牺牲掉了，剩下一个纯色盾牌形状。
    ///
    /// 3. **并排 + 直接叠加**（第三、四版）：先是盾牌和一个独立画的符号（描边眼睛/
    ///    三角形）挨着放，再收紧间距甚至让两者的包围盒相交、谁后画谁盖住重叠处。
    ///    这条路线的根本问题到第四版才彻底暴露：盾牌的棋盘格本身有两个镂空格子，
    ///    符号（尤其描边眼睛）自己中间也是镂空的——两个"镂空"的图形直接做 alpha
    ///    重叠，遮挡效果完全取决于重叠点具体落在谁的哪个镂空/实心区域，家长看到的
    ///    是"两个图标随便怼在一起"，而不是一个统一设计的图标。用户反馈原话："缺少
    ///    设计感，只是拼接"，说得准确。
    ///
    /// 4. **圆形徽章 + 挖洞 + 实心 + 镂空图案**（当前版本）：解法是不再让两个"镂空"
    ///    图形互相重叠，而是学真正的图标系统（iOS/macOS 角标、Slack 的小红点那一类）
    ///    分三步走：① 在盾牌右下角先挖一个比徽章本身略大的圆洞（`.clear` 合成模式，
    ///    把盾牌在这块区域的棋盘格/描边全部擦成透明，不管原来是实心还是镂空，统一
    ///    清零）；② 在挖出来的洞中央画一个**实心**圆徽章；③ 再从这个实心圆里镂空
    ///    刻出图案。徽章本身永远是实心的，图案永远是"从实心里抠出来的镂空"，不会再
    ///    出现"我这块透明、你那块也透明，叠在一起变成什么谁也说不准"的情况——这正是
    ///    iOS 角标"先挖白边、再填色、再放图标"三段式的单色版本。挖洞比徽章大一圈
    ///    （knockoutRatio）留出的空隙，让徽章和盾牌的棋盘格/描边线保持一点呼吸空间。
    ///
    /// 5. **徽章里的图案必须是实心剪影**（当前版本最后一次修正）：第 4 版一开始在徽章里
    ///    刻的还是眼睛（杏仁镂空环 + 瞳孔）和三角感叹号（三角框 + 感叹号），结果仍然糊。
    ///    这次算了笔账才找到真原因：16pt 图标下徽章直径只有 9.3pt，眼睛的**环带**厚度
    ///    只剩约 1pt——2x 屏上 2 像素，1x 屏上 1 像素。任何"需要两个色阶才能读出来"的
    ///    结构（环带 + 中心、外框 + 内容）在这个尺寸下都不可能成立，这是物理限制，不是
    ///    画得不够好。凡是内部还有结构的图案，一律换成**单一实心剪影**之后立刻就清楚了。
    ///    所以现在：看=实心圆点（也是"录制中"的通用符号），出问题=裸感叹号（去掉三角外框，
    ///    框对语义没贡献却要吃掉一半像素预算）。
    ///
    /// 需要更丰富的图形（真正的眼睛、带框三角）的地方是「关于」窗口和各种弹窗——那里
    /// 尺寸够，可以放；菜单栏这 16pt 就老实用剪影。
    enum Variant {
        /// 已守护、未开启截图：只有盾牌，不带任何徽章
        case brand
        /// 截图已开启：盾牌右下角 + 实心圆点徽章
        case watching
        /// 此刻正在截图：盾牌右下角 + 同心圆徽章（相对实心点多一圈，读作快门张开）
        case capturing
        /// 缺少系统权限：盾牌右下角 + 感叹号徽章
        case warning
    }

    /// 徽章直径相对盾牌宽度的比例。
    private static let badgeSizeRatio: CGFloat = 0.58
    /// 挖洞半径相对徽章半径的倍数：挖洞比徽章本身大一圈，在徽章和盾牌之间留一条
    /// 干净的呼吸缝，避免徽章边缘和盾牌的棋盘格/描边线像素级硬碰硬。
    private static let knockoutRatio: CGFloat = 1.22
    /// 徽章圆心位置，取盾牌自身坐标系（0...pointSize 宽、0...shieldHeight 高）的比例。
    /// 偏右下——贴近盾牌的尖角，是徽章"挂"在盾牌上最自然的位置，也符合角标的
    /// 通行放法（iOS App 角标同样是右上/右下角，不会放在图形正中间）。
    private static let badgeCenterXRatio: CGFloat = 0.80
    private static let badgeCenterYRatio: CGFloat = 0.24

    /// - Parameter pointSize: 盾牌的宽度。带徽章的状态整体会比盾牌本身略宽/略高一点
    ///   （徽章会有一小部分探出盾牌的右下角轮廓，这是角标的常见画法），菜单栏用的是
    ///   `NSStatusItem.variableLength`，尺寸随状态变化本来就是支持的。
    static func image(pointSize: CGFloat, variant: Variant = .brand) -> NSImage {
        let shieldBox = NSSize(width: pointSize, height: pointSize * aspectRatio)
        let badgeR = pointSize * badgeSizeRatio / 2
        let knockoutR = badgeR * knockoutRatio
        // 徽章圆心在"盾牌本身矩形"坐标系里的位置；如果徽章需要探出盾牌右边/顶边/
        // 底边，画布要跟着放大，否则探出去的部分会被裁掉。整个画布以盾牌左下角为
        // 原点，plainCenter 是徽章圆心相对盾牌矩形左下角的坐标。
        let plainCenter = NSPoint(x: pointSize * badgeCenterXRatio, y: shieldBox.height * badgeCenterYRatio)
        let overflowRight = variant == .brand ? 0 : max(0, plainCenter.x + knockoutR - shieldBox.width)
        let overflowBottom = variant == .brand ? 0 : max(0, knockoutR - plainCenter.y)
        let overflowTop = variant == .brand ? 0 : max(0, plainCenter.y + knockoutR - shieldBox.height)
        let size = NSSize(width: shieldBox.width + overflowRight,
                          height: shieldBox.height + overflowBottom + overflowTop)

        let image = NSImage(size: size)
        image.lockFocus()

        let inset = pointSize * 0.06
        let shieldRect = NSRect(x: 0, y: overflowBottom, width: shieldBox.width, height: shieldBox.height)
            .insetBy(dx: inset, dy: inset)
        drawBrandShield(in: shieldRect, lineWidth: pointSize * 0.09)

        if variant != .brand {
            let center = NSPoint(x: plainCenter.x, y: plainCenter.y + overflowBottom)
            drawBadge(center: center, radius: badgeR, knockoutRadius: knockoutR, variant: variant)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - 盾牌

    private static func drawBrandShield(in rect: NSRect, lineWidth: CGFloat) {
        let shield = shieldPath(in: rect)

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

    private static func shieldPath(in rect: NSRect) -> NSBezierPath {
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

    // MARK: - 徽章

    /// 徽章统一走"挖洞 → 填实心圆 → 从实心圆里镂空刻图案"三段式，见 Variant 文档
    /// 第 4 条。三种非默认状态共享这套底座，只有第三步"刻什么图案"不同。
    private static func drawBadge(center: NSPoint, radius: CGFloat, knockoutRadius: CGFloat, variant: Variant) {
        clearCircle(center: center, radius: knockoutRadius)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()

        switch variant {
        case .brand:
            break
        case .watching:
            cutCircle(center: center, radius: radius * 0.40)
        case .capturing:
            cutRing(center: center, outerRadius: radius * 0.52, innerRadius: radius * 0.22)
        case .warning:
            cutExclamation(center: center, badgeRadius: radius)
        }
    }

    private static func clearCircle(center: NSPoint, radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 实心圆点镂空——"正在被看着"。
    ///
    /// 为什么是个点而不是眼睛：徽章直径在 16pt 图标下只有 9.3pt，能放进去的图案还要再
    /// 小一圈。眼睛这种**需要两个色阶才能读出**的形状（眼眶环 + 中间瞳孔）在这里环带
    /// 只剩约 1pt（2x 屏上 2 像素），渲染出来必然是一团糊的疙瘩——这不是画得不够好看，
    /// 是物理上不够放。实测把眼睛、三角形这类带内部结构的图案换成**实心剪影**之后，
    /// 同样尺寸下立刻就清晰了。圆点同时也是"录制中"最通用的符号，家长不用学。
    private static func cutCircle(center: NSPoint, radius: CGFloat) {
        clearCircle(center: center, radius: radius)
    }

    /// 同心圆镂空——"此刻正在拍这一张"。相对实心点多一圈，读作快门张开；这个状态是
    /// 瞬时的（截图那一下才出现），即使和实心点区分得不那么强烈也不影响理解。
    private static func cutRing(center: NSPoint, outerRadius: CGFloat, innerRadius: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius, y: center.y - outerRadius,
                                               width: outerRadius * 2, height: outerRadius * 2))
        path.windingRule = .evenOdd
        path.append(NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                                width: innerRadius * 2, height: innerRadius * 2)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 感叹号镂空（竖条 + 圆点）——"有事要你处理"。
    ///
    /// 刻意**不画三角形外框**：三角框加内部感叹号同样是"需要两个色阶"的结构，在徽章
    /// 尺寸下三条边会和里面的感叹号糊成一块。裸感叹号只有两个实心块，任何尺寸都清晰，
    /// 而且"!"本身就是通用的警示符号，外框那圈三角对语义没有额外贡献。
    private static func cutExclamation(center: NSPoint, badgeRadius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        let barW = badgeRadius * 0.24
        NSBezierPath(roundedRect: NSRect(x: center.x - barW / 2, y: center.y - badgeRadius * 0.05,
                                         width: barW, height: badgeRadius * 0.52),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        let dotD = badgeRadius * 0.26
        NSBezierPath(ovalIn: NSRect(x: center.x - dotD / 2, y: center.y - badgeRadius * 0.52,
                                    width: dotD, height: dotD)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
