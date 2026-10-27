// Draws the Lumen app icon ("Eclissi": a crescent of light on cream) and writes an .iconset folder.
// The same design as an SVG is docs/assets/logo-prototypes/crescent.svg.
// Usage: swift tools/make-icon.swift <output.iconset>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func render(pixels px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let t = NSAffineTransform()
    t.scale(by: s)
    t.concat()

    // Body: macOS-style rounded square inside the 1024 canvas.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    body.addClip()

    // "Eclissi": a dark disc covers a sun and leaves a crescent of light on a cream body.
    NSGradient(colors: [color(0xFBF4E6), color(0xEADCC2)])!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), angle: -90)

    // Coral halo around the sun.
    let sun = NSPoint(x: 552, y: 552)
    NSGradient(colorsAndLocations: (color(0xFF7A3A, 0.4), 0), (color(0xFF7A3A, 0.4), 0.55), (color(0xFF7A3A, 0), 1))!
        .draw(fromCenter: sun, radius: 0, toCenter: sun, radius: 430, options: [])

    // Sun: amber at top-left to coral at bottom-right.
    let sunPath = NSBezierPath(ovalIn: NSRect(x: sun.x - 300, y: sun.y - 300, width: 600, height: 600))
    NSGraphicsContext.saveGraphicsState()
    sunPath.addClip()
    NSGradient(colors: [color(0xFFC24A), color(0xFF5A2A)])!
        .draw(in: NSRect(x: sun.x - 300, y: sun.y - 300, width: 600, height: 600), angle: -45)
    NSGraphicsContext.restoreGraphicsState()

    // Dark disc, offset towards the bottom-left, with a faint highlight at its top-left.
    let disc = NSPoint(x: 462, y: 472)
    let discPath = NSBezierPath(ovalIn: NSRect(x: disc.x - 300, y: disc.y - 300, width: 600, height: 600))
    NSGraphicsContext.saveGraphicsState()
    discPath.addClip()
    NSGradient(colors: [color(0x3B3752), color(0x14121D)])!
        .draw(fromCenter: NSPoint(x: disc.x - 90, y: disc.y + 120), radius: 0,
              toCenter: NSPoint(x: disc.x - 90, y: disc.y + 120), radius: 540, options: [])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Lumen.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let files: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in files {
    try render(pixels: px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
