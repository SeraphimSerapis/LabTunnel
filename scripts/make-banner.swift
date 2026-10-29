// Draws the README banner from the app icon, so the two stay in sync.
// Usage: swift scripts/make-banner.swift docs/banner.png
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 1600, height = 500
let size = NSSize(width: width, height: height)

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// Card: the icon's indigo and teal, darkened so white text stays readable.
let card = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 36, yRadius: 36)
card.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.04, green: 0.06, blue: 0.17, alpha: 1),
    NSColor(srgbRed: 0.07, green: 0.12, blue: 0.30, alpha: 1),
    NSColor(srgbRed: 0.03, green: 0.36, blue: 0.46, alpha: 1),
])!.draw(in: card, angle: 15)

/// The menu bar glyph in a flat color.
func glyph(pointSize: CGFloat, color: NSColor) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let symbol = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    return NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

// A large, faint copy of the glyph bleeding off the right edge.
let watermark = glyph(pointSize: 440, color: .white)
watermark.draw(in: NSRect(x: CGFloat(width) - watermark.size.width * 0.62, y: (CGFloat(height) - watermark.size.height) / 2,
                          width: watermark.size.width, height: watermark.size.height),
               from: .zero, operation: .sourceOver, fraction: 0.07)

// The app icon. The .icns already carries Apple's padding and shadow.
let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns")!
let iconSide: CGFloat = 360
icon.draw(in: NSRect(x: 70, y: (CGFloat(height) - iconSide) / 2, width: iconSide, height: iconSide))

func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) -> NSSize {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    string.draw(at: point)
    return string.size()
}

let textX: CGFloat = 470
_ = draw("LabTunnel", font: .systemFont(ofSize: 124, weight: .bold), color: .white, at: NSPoint(x: textX - 6, y: 258))
_ = draw("SSH port forwarding from your Mac's menu bar.",
         font: .systemFont(ofSize: 40, weight: .medium), color: NSColor.white.withAlphaComponent(0.78),
         at: NSPoint(x: textX, y: 196))

/// A rounded chip like a row in the app's menu, with the green "connected" dot.
func chip(at origin: NSPoint, dot: NSColor?, parts: [(String, NSFont, NSColor)]) -> CGFloat {
    let padding: CGFloat = 26, gap: CGFloat = 16, dotSize: CGFloat = 16, chipHeight: CGFloat = 70
    let strings = parts.map { NSAttributedString(string: $0.0, attributes: [.font: $0.1, .foregroundColor: $0.2]) }
    let textWidth = strings.map { $0.size().width }.reduce(0, +) + gap * CGFloat(strings.count - 1)
    let chipWidth = padding * 2 + textWidth + (dot == nil ? 0 : dotSize + gap)
    let rect = NSRect(x: origin.x, y: origin.y, width: chipWidth, height: chipHeight)
    let shape = NSBezierPath(roundedRect: rect, xRadius: chipHeight / 2, yRadius: chipHeight / 2)
    NSColor.white.withAlphaComponent(0.09).setFill()
    shape.fill()
    NSColor.white.withAlphaComponent(0.16).setStroke()
    shape.lineWidth = 2
    shape.stroke()

    var x = rect.minX + padding
    if let dot {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = dot.withAlphaComponent(0.8)
        glow.shadowBlurRadius = 10
        glow.set()
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
        NSGraphicsContext.restoreGraphicsState()
        x += dotSize + gap
    }
    for string in strings {
        let textSize = string.size()
        string.draw(at: NSPoint(x: x, y: rect.midY - textSize.height / 2))
        x += textSize.width + gap
    }
    return chipWidth
}

let mono = NSFont.monospacedSystemFont(ofSize: 27, weight: .medium)
let chipY: CGFloat = 88
let routeWidth = chip(at: NSPoint(x: textX, y: chipY),
                      dot: NSColor(srgbRed: 0.20, green: 0.84, blue: 0.40, alpha: 1),
                      parts: [("Grafana", .systemFont(ofSize: 28, weight: .semibold), .white),
                              ("homelab:3000 → 127.0.0.1:3000", mono, NSColor.white.withAlphaComponent(0.72))])
_ = chip(at: NSPoint(x: textX + routeWidth + 20, y: chipY), dot: nil,
         parts: [("$", mono, NSColor(srgbRed: 0.35, green: 0.85, blue: 0.90, alpha: 1)),
                 ("labtunnel connect", mono, NSColor.white.withAlphaComponent(0.85))])

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
