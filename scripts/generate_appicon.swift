#!/usr/bin/env swift
// 生成 AppIcon.iconset 各尺寸 PNG（品牌盾牌：蓝底 #0284c7 + 白棋盘格 + 蓝描边，
// 与 dashboard favicon 同一套视觉）。运行后再用 iconutil 打成 AppIcon.icns：
//   swift scripts/generate_appicon.swift
//   iconutil -c icns build/AppIcon.iconset -o BigDaddy/AppIcon.icns
// 盾牌路径与 AppDelegate.swift 里的 ShieldIcon 保持一致（比例 340:400）。

import AppKit

let brandBlue = NSColor(srgbRed: 0x02 / 255.0, green: 0x84 / 255.0, blue: 0xC7 / 255.0, alpha: 1)

func shieldPath(in rect: NSRect) -> NSBezierPath {
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

func renderIcon(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixelSize)
    // macOS 图标惯例：内容四周留 ~10% 空白；盾牌比宽高 340:400，按高度撑满内容区居中
    let margin = s * 0.10
    let contentH = s - margin * 2
    let contentW = contentH * 340.0 / 400.0
    let rect = NSRect(x: (s - contentW) / 2, y: margin, width: contentW, height: contentH)
    // 描边有一半在路径外侧，把盾牌 rect 再往内收一点避免被画布裁掉
    let stroke = max(s * 0.04, 1)
    let shieldRect = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
    let shield = shieldPath(in: shieldRect)

    brandBlue.setFill()
    shield.fill()

    NSGraphicsContext.saveGraphicsState()
    shield.addClip()
    NSColor.white.setFill()
    let cellW = shieldRect.width / 2, cellH = shieldRect.height / 2
    // 左上、右下填白（AppKit 坐标系 y 向上：左上 = row 1 col 0，右下 = row 0 col 1）
    NSRect(x: shieldRect.minX, y: shieldRect.minY + cellH, width: cellW, height: cellH).fill()
    NSRect(x: shieldRect.minX + cellW, y: shieldRect.minY, width: cellW, height: cellH).fill()
    NSGraphicsContext.restoreGraphicsState()

    brandBlue.setStroke()
    shield.lineWidth = stroke
    shield.lineJoinStyle = .round
    shield.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in entries {
    try! renderIcon(pixelSize: size).write(to: iconset.appendingPathComponent(name))
}
print("Wrote \(entries.count) PNGs to \(iconset.path)")
