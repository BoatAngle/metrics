// Renders a simple gauge-style app icon into an .iconset directory.
// Usage: swift scripts/make_icon.swift build/AppIcon.iconset
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = size
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.16, alpha: 1),
                              ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1))!
    gradient.draw(in: bg, angle: -90)

    // Gauge arc
    let center = NSPoint(x: s / 2, y: s * 0.44)
    let radius = s * 0.26
    func arc(_ from: CGFloat, _ to: CGFloat, color: NSColor, width: CGFloat) {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }
    arc(-30, 210, color: NSColor.white.withAlphaComponent(0.16), width: s * 0.065)
    arc(80, 210, color: NSColor(calibratedRed: 0.29, green: 0.85, blue: 0.5, alpha: 1), width: s * 0.065)

    // Needle
    let needle = NSBezierPath()
    needle.move(to: center)
    let angle: CGFloat = 120 * .pi / 180
    needle.line(to: NSPoint(x: center.x + cos(angle) * radius * 0.72, y: center.y + sin(angle) * radius * 0.72))
    needle.lineWidth = s * 0.035
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    let hub = NSBezierPath(ovalIn: NSRect(x: center.x - s * 0.035, y: center.y - s * 0.035, width: s * 0.07, height: s * 0.07))
    NSColor.white.setFill()
    hub.fill()

    // Tiny bars under the gauge
    let barW = s * 0.05, gap = s * 0.028
    let heights: [CGFloat] = [0.35, 0.6, 0.45, 0.8, 0.55]
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = s / 2 - totalW / 2
    for h in heights {
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: s * 0.17, width: barW, height: s * 0.1 * h + s * 0.02),
                               xRadius: barW / 3, yRadius: barW / 3)
        NSColor(calibratedRed: 0.29, green: 0.85, blue: 0.5, alpha: 0.85).setFill()
        bar.fill()
        x += barW + gap
    }
    return rep
}

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in entries {
    let rep = draw(size: CGFloat(px))
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: outDir.appendingPathComponent(name))
}
print("iconset written to \(outDir.path)")
