import AppKit

/// 自绘的盾牌图标：轮廓内部是 2×2 棋盘格，替代系统 SF Symbol 的纯轮廓 shield，
/// 用于菜单栏未截图状态和各处弹窗图标。系统 SF Symbols 里没有棋盘格盾牌这个图形，
/// 用 Bezier 路径手绘 + 裁剪填充实现，可以在任意尺寸下重新栅格化，不依赖位图资源。
enum ShieldIcon {
    private static let aspectRatio: CGFloat = 400.0 / 340.0 // 高/宽

    /// 盾牌的四种内部形态。**轮廓永远不变**——家长和孩子只需要认一次"这个盾牌就是
    /// BigDaddy"，之后所有状态变化都发生在盾牌内部。
    ///
    /// 此前三种非默认状态分别借用 eye / exclamationmark.triangle / camera 三个系统符号，
    /// 彼此之间、和盾牌之间都没有任何形状上的关联：家长看到菜单栏冒出一个三角感叹号，
    /// 根本想不到那还是同一个 App，只会以为系统出了什么毛病。用同一副轮廓 + 不同内胆，
    /// "这是 BigDaddy"和"它现在处于什么状态"这两件事才能一眼分开读。
    ///
    /// 空心/实心承担最重要的那条区分——截图开着还是关着。这是孩子最该一眼看出来的事，
    /// 也是产品"始终可见，从不隐瞒"这句承诺的实际落点。
    enum Variant {
        /// 已守护、未开启截图：棋盘格内胆（品牌标识本身）
        case brand
        /// 截图已开启：整面填实，和空心态形成最大反差
        case watching
        /// 此刻正在截图：填实 + 中央挖空一个圆孔，像快门张开
        case capturing
        /// 缺少系统权限：空心（说明确实没在截图）+ 中央一个感叹号
        case warning
    }

    static func image(pointSize: CGFloat, variant: Variant = .brand) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize * aspectRatio)
        let image = NSImage(size: size)
        image.lockFocus()

        let inset = pointSize * 0.06
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let shield = path(in: rect)
        let w = rect.width, h = rect.height

        NSColor.black.setFill()
        switch variant {
        case .brand:
            NSGraphicsContext.saveGraphicsState()
            shield.addClip()
            let gridCount = 2
            let cellW = rect.width / CGFloat(gridCount)
            let cellH = rect.height / CGFloat(gridCount)
            for row in 0..<gridCount {
                for col in 0..<gridCount where (row + col) % 2 == 0 {
                    NSRect(x: rect.minX + CGFloat(col) * cellW, y: rect.minY + CGFloat(row) * cellH,
                           width: cellW, height: cellH).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()

        case .watching:
            shield.fill()

        case .capturing:
            shield.fill()
            // 在填实的盾牌上挖掉一个圆孔。模板图只看 alpha 通道，所以这里必须真的把像素
            // 清成透明（.clear），画一个白色圆是没用的——白色在深色菜单栏里会被重新着色。
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: centeredDot(in: rect, diameterRatio: 0.34, centerYRatio: 0.56)).fill()
            NSGraphicsContext.restoreGraphicsState()

        case .warning:
            // 竖条 + 圆点组成感叹号。保持空心是有意的：缺权限时确实一张截图也拍不到，
            // 内胆读法要和"未开启截图"一致，只是多了个"有事要处理"的记号。
            let barW = w * 0.16
            NSBezierPath(
                roundedRect: NSRect(x: rect.midX - barW / 2, y: rect.minY + 0.46 * h, width: barW, height: 0.32 * h),
                xRadius: barW / 2, yRadius: barW / 2
            ).fill()
            NSBezierPath(ovalIn: centeredDot(in: rect, diameterRatio: 0.19, centerYRatio: 0.34)).fill()
        }

        NSColor.black.setStroke()
        shield.lineWidth = pointSize * 0.09
        shield.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 盾牌内部一个水平居中的圆的外接矩形。直径按宽度取比例、纵向位置按高度取比例——
    /// 盾牌不是正方形，两个方向混用同一个基准会让圆在视觉上偏离中轴。
    private static func centeredDot(in rect: NSRect, diameterRatio: CGFloat, centerYRatio: CGFloat) -> NSRect {
        let d = rect.width * diameterRatio
        return NSRect(x: rect.midX - d / 2, y: rect.minY + centerYRatio * rect.height - d / 2, width: d, height: d)
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
