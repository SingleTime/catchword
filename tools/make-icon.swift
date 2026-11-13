// 生成 App 图标：tools/make-icon.swift
// 用法：swift tools/make-icon.swift
import AppKit
import CoreGraphics

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = (size - inset * 2) * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 底色渐变
    let top = NSColor(srgbRed: 0.145, green: 0.196, blue: 0.353, alpha: 1)     // #25325A
    let bottom = NSColor(srgbRed: 0.043, green: 0.545, blue: 0.541, alpha: 1)  // #0B8B8A
    if let g = NSGradient(starting: top, ending: bottom) {
        g.draw(in: path, angle: -70)
    }

    // 顶部高光
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let hl = NSBezierPath(ovalIn: NSRect(x: -inset, y: size * 0.55, width: size * 1.4, height: size * 0.9))
    NSColor.white.withAlphaComponent(0.07).setFill()
    hl.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 取景框 + 文本线条（用矢量绘制，缩小时依然清晰）
    let cx = size / 2, cy = size / 2
    let boxW = size * 0.42, boxH = size * 0.42
    let box = NSRect(x: cx - boxW / 2, y: cy - boxH / 2, width: boxW, height: boxH)
    let corner = boxW * 0.28
    let lineW = max(2, size * 0.045)

    NSColor.white.withAlphaComponent(0.95).setStroke()
    let brackets = NSBezierPath()
    brackets.lineWidth = lineW
    brackets.lineCapStyle = .round
    // 左上
    brackets.move(to: NSPoint(x: box.minX, y: box.maxY - corner))
    brackets.line(to: NSPoint(x: box.minX, y: box.maxY))
    brackets.line(to: NSPoint(x: box.minX + corner, y: box.maxY))
    // 右上
    brackets.move(to: NSPoint(x: box.maxX - corner, y: box.maxY))
    brackets.line(to: NSPoint(x: box.maxX, y: box.maxY))
    brackets.line(to: NSPoint(x: box.maxX, y: box.maxY - corner))
    // 右下
    brackets.move(to: NSPoint(x: box.maxX, y: box.minY + corner))
    brackets.line(to: NSPoint(x: box.maxX, y: box.minY))
    brackets.line(to: NSPoint(x: box.maxX - corner, y: box.minY))
    // 左下
    brackets.move(to: NSPoint(x: box.minX + corner, y: box.minY))
    brackets.line(to: NSPoint(x: box.minX, y: box.minY))
    brackets.line(to: NSPoint(x: box.minX, y: box.minY + corner))
    brackets.stroke()

    // 中间三条文本线（长短不一，暗示"词"）
    let lineH = max(1.5, size * 0.038)
    let lx = cx - boxW * 0.26
    let lengths: [CGFloat] = [0.52, 0.40, 0.30]
    NSColor.white.setFill()
    for (i, len) in lengths.enumerated() {
        let y = cy + boxH * 0.20 - CGFloat(i) * boxH * 0.20
        let w = boxW * len
        let r = NSRect(x: lx, y: y, width: w, height: lineH)
        NSBezierPath(roundedRect: r, xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let mapping: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, px) in mapping {
    if let data = render(px) {
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
print("iconset 生成完毕：\(outDir.path)")
