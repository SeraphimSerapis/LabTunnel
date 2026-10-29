// Draws the app icon at every size macOS wants and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>   (scripts/make-icon.sh wraps this)
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// The menu bar glyph in white, so the Dock icon and the menu bar item read as one thing.
func glyph(pointSize: CGFloat) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let symbol = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    return NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Apple's template: an 824pt squircle centered on a 1024pt canvas, with room for a shadow.
    let body = NSRect(x: size * 0.0977, y: size * 0.0977, width: size * 0.8047, height: size * 0.8047)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.18, blue: 0.42, alpha: 1),  // deep indigo, bottom
        NSColor(srgbRed: 0.05, green: 0.62, blue: 0.72, alpha: 1),  // teal, top
    ])!.draw(in: path, angle: 70)

    // A faint top highlight keeps the flat gradient from looking dull.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.16)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let mark = glyph(pointSize: body.width * 0.5)
    let scale = body.width * 0.56 / max(mark.size.width, mark.size.height)
    let markSize = NSSize(width: mark.size.width * scale, height: mark.size.height * scale)
    mark.draw(in: NSRect(x: body.midX - markSize.width / 2, y: body.midY - markSize.height / 2,
                         width: markSize.width, height: markSize.height))

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

// Each entry: file name, pixel size.
let files: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in files {
    try render(pixels: pixels).write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
