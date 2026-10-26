// Draws the Lumen app icon and writes an .iconset folder.
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

    NSGradient(colors: [color(0x23284F), color(0x090B16)])!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), angle: -90)

    // Soft warm glow behind the orb.
    NSGradient(colors: [color(0xFFD68A, 0.55), color(0xFFD68A, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 530), radius: 0,
              toCenter: NSPoint(x: 512, y: 530), radius: 430, options: [])

    // Thin ring.
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - 235, y: 530 - 235, width: 470, height: 470))
    ring.lineWidth = 10
    color(0xFFFFFF, 0.28).setStroke()
    ring.stroke()

    // Orb.
    NSGradient(colors: [color(0xFFFFFF), color(0xFFE2A3)])!
        .draw(fromCenter: NSPoint(x: 490, y: 565), radius: 0,
              toCenter: NSPoint(x: 512, y: 530), radius: 160, options: [])
    let orb = NSBezierPath(ovalIn: NSRect(x: 512 - 160, y: 530 - 160, width: 320, height: 320))
    NSGraphicsContext.saveGraphicsState()
    orb.addClip()
    NSGradient(colors: [color(0xFFFFFF), color(0xFFD98A)])!
        .draw(fromCenter: NSPoint(x: 470, y: 590), radius: 0,
              toCenter: NSPoint(x: 512, y: 530), radius: 170, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Subtle top sheen on the body.
    NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)

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
