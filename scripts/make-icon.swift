// Renders the app icon and packs it into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (needs macOS `iconutil` and `sips`)
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(in ctx: CGContext) {
    // Standard macOS icon grid: 824 pt tile inside the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x2A2F8F))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: indigo → violet, with a soft glow in the top-left.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x8B6CFF), color(0x5B4BF0), color(0x23287A)], [0, 0.45, 1]),
                           start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: [])
    // Faint dotted grid, like a notepad.
    ctx.setFillColor(color(0xFFFFFF, 0.07))
    for x in stride(from: 150.0, through: 900.0, by: 56) {
        for y in stride(from: 150.0, through: 900.0, by: 56) {
            ctx.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
        }
    }
    // Top edge highlight.
    ctx.addPath(roundedRect(tile.insetBy(dx: 2, dy: 2), 184))
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // The scratch sheet, tilted slightly, with a folded corner.
    ctx.saveGState()
    ctx.translateBy(x: 488, y: 520)
    ctx.rotate(by: 7 * .pi / 180)
    let w: CGFloat = 520, h: CGFloat = 610, fold: CGFloat = 118, r: CGFloat = 46
    let sheet = CGMutablePath()
    let x0 = -w / 2, y0 = -h / 2, x1 = w / 2, y1 = h / 2
    sheet.move(to: CGPoint(x: x0 + r, y: y0))
    sheet.addLine(to: CGPoint(x: x1 - r, y: y0))
    sheet.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
    sheet.addLine(to: CGPoint(x: x1, y: y1 - fold))
    sheet.addLine(to: CGPoint(x: x1 - fold, y: y1))
    sheet.addLine(to: CGPoint(x: x0 + r, y: y1))
    sheet.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
    sheet.addLine(to: CGPoint(x: x0, y: y0 + r))
    sheet.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
    sheet.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: color(0x0B0D3A, 0.45))
    ctx.addPath(sheet)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(sheet)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xEEF0FF)], [0, 1]),
                           start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y0), options: [])
    // Gutter strip with line markers.
    ctx.setFillColor(color(0xE4E7FB))
    ctx.fill(CGRect(x: x0, y: y0, width: 74, height: h))
    ctx.restoreGState()

    // Folded corner.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: x1 - fold, y: y1))
    flap.addLine(to: CGPoint(x: x1 - fold + 14, y: y1 - fold + 14))
    flap.addQuadCurve(to: CGPoint(x: x1, y: y1 - fold), control: CGPoint(x: x1 - fold + 4, y: y1 - fold - 2))
    flap.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -6, height: -6), blur: 14, color: color(0x1B1F5C, 0.3))
    ctx.addPath(flap)
    ctx.setFillColor(color(0xD9DDFB))
    ctx.fillPath()
    ctx.restoreGState()

    // Syntax-highlighted code lines.
    let purple = color(0x8B5CF6), blue = color(0x3B82F6), green = color(0x10B981)
    let orange = color(0xF59E0B), pink = color(0xEC4899), slate = color(0xC7CCE6)
    let lines: [(indent: CGFloat, bars: [(CGFloat, CGColor)])] = [
        (0, [(118, purple), (150, blue)]),
        (44, [(96, pink), (170, green)]),
        (44, [(140, orange), (84, blue)]),
        (88, [(190, green)]),
        (44, [(70, purple)]),
        (0, [(210, slate)]),
        (0, [(96, purple), (120, orange)]),
    ]
    let barH: CGFloat = 30, gap: CGFloat = 20, left = x0 + 108
    var y = y1 - 118
    for (i, line) in lines.enumerated() {
        ctx.setFillColor(color(0xA9B0DB))
        ctx.fillEllipse(in: CGRect(x: x0 + 30, y: y + barH / 2 - 7, width: 14, height: 14))
        var x = left + line.indent
        for (width, c) in line.bars {
            ctx.addPath(roundedRect(CGRect(x: x, y: y, width: width, height: barH), barH / 2))
            ctx.setFillColor(c)
            ctx.fillPath()
            x += width + gap
        }
        if i == 4 {
            ctx.setFillColor(color(0x4F46E5))
            ctx.addPath(roundedRect(CGRect(x: x + 2, y: y - 12, width: 12, height: barH + 24), 6))
            ctx.fillPath()
        }
        y -= 66
    }
    ctx.restoreGState()

    // Run button.
    let center = CGPoint(x: 718, y: 300), radius: CGFloat = 124
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: color(0x03261A, 0.5))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: center.x - radius - 16, y: center.y - radius - 16, width: 2 * radius + 32, height: 2 * radius + 32))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x4ADE80), color(0x10B981), color(0x047857)], [0, 0.55, 1]),
                           start: CGPoint(x: center.x, y: center.y + radius), end: CGPoint(x: center.x, y: center.y - radius), options: [])
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: center.x - 40, y: center.y + 60), startRadius: 0,
                           endCenter: CGPoint(x: center.x - 40, y: center.y + 60), endRadius: 150, options: [])
    ctx.restoreGState()
    let play = CGMutablePath()
    let t: CGFloat = 62
    play.move(to: CGPoint(x: center.x - t * 0.62, y: center.y + t))
    play.addLine(to: CGPoint(x: center.x + t * 1.02, y: center.y))
    play.addLine(to: CGPoint(x: center.x - t * 0.62, y: center.y - t))
    play.closeSubpath()
    ctx.saveGState()
    ctx.setLineJoin(.round)
    ctx.setLineWidth(22)
    ctx.addPath(play)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
