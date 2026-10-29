// Draws the app icon (a merge graph on a dark tile) and writes an .icns file.
// Usage: swift scripts/make-icon.swift <output.icns>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func drawIcon(size s: CGFloat) {
    // macOS icon grid: the tile fills about 80% of the canvas.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.225

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowBlurRadius = s * 0.025
    shadow.set()
    color(0x1D1D1F).setFill()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Two branches: a straight trunk on the left, a feature branch curving back into it.
    let unit = tile.width
    let trunkX = tile.minX + unit * 0.36
    let branchX = tile.minX + unit * 0.66
    let top = tile.minY + unit * 0.76
    let bottom = tile.minY + unit * 0.24
    let mid = tile.minY + unit * 0.5
    let line = unit * 0.075

    let trunk = NSBezierPath()
    trunk.move(to: NSPoint(x: trunkX, y: bottom))
    trunk.line(to: NSPoint(x: trunkX, y: top))
    trunk.lineWidth = line
    trunk.lineCapStyle = .round
    color(0x6E8BFF).setStroke()
    trunk.stroke()

    let branch = NSBezierPath()
    branch.move(to: NSPoint(x: branchX, y: top - unit * 0.06))
    branch.line(to: NSPoint(x: branchX, y: mid + unit * 0.08))
    branch.curve(to: NSPoint(x: trunkX, y: bottom + unit * 0.12),
                 controlPoint1: NSPoint(x: branchX, y: mid - unit * 0.1),
                 controlPoint2: NSPoint(x: trunkX, y: mid - unit * 0.02))
    branch.lineWidth = line
    branch.lineCapStyle = .round
    color(0xF28A3C).setStroke()
    branch.stroke()

    let dot = unit * 0.17
    for (point, hex) in [(NSPoint(x: trunkX, y: top), UInt32(0x6E8BFF)),
                         (NSPoint(x: branchX, y: top - unit * 0.06), 0xF28A3C),
                         (NSPoint(x: trunkX, y: bottom), 0x6E8BFF)] {
        let rect = NSRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
        color(0x1D1D1F).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -line * 0.45, dy: -line * 0.45)).fill()
        color(hex).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
