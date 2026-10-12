// Renders Resources/AppIcon.icns: a dark squircle with the overlay's white waveform bars.
// swift scripts/make-icon.swift
import Cocoa

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.24, alpha: 1),
                        NSColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1)])!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    shape.lineWidth = 4 * s
    shape.stroke()
    let heights: [CGFloat] = [0.18, 0.32, 0.55, 0.8, 0.5, 0.95, 0.62, 0.36, 0.7, 0.42, 0.22]
    let barWidth = 34 * s, gap = 22 * s
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let height = (60 + h * 420) * s
        NSBezierPath(roundedRect: NSRect(x: x, y: body.midY - height / 2, width: barWidth, height: height),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
