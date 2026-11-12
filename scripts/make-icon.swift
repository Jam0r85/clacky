// Renders Resources/AppIcon.icns: an orange keycap on a dark rounded square.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Background tile (Apple's icon grid: 824pt square, ~185pt corner radius).
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x3A3F4B), ending: color(0x16181E))!.draw(in: tile, angle: -90)

    // Soft shadow under the keycap.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.55)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    let base = NSRect(x: 222, y: 236, width: 580, height: 540)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 110, yRadius: 110)
    color(0xC9481F).setFill()
    basePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Keycap skirt: four shaded faces between the base and the top surface.
    let top = NSRect(x: 312, y: 392, width: 400, height: 330)
    NSGraphicsContext.saveGraphicsState()
    basePath.addClip()
    func face(_ points: [NSPoint], _ fill: NSColor) {
        let p = NSBezierPath()
        p.move(to: points[0])
        points.dropFirst().forEach { p.line(to: $0) }
        p.close()
        fill.setFill()
        p.fill()
    }
    let (bl, br, tr, tl) = (NSPoint(x: base.minX, y: base.minY), NSPoint(x: base.maxX, y: base.minY),
                            NSPoint(x: base.maxX, y: base.maxY), NSPoint(x: base.minX, y: base.maxY))
    let (ibl, ibr, itr, itl) = (NSPoint(x: top.minX, y: top.minY), NSPoint(x: top.maxX, y: top.minY),
                                NSPoint(x: top.maxX, y: top.maxY), NSPoint(x: top.minX, y: top.maxY))
    face([bl, br, ibr, ibl], color(0xB43E18)) // front
    face([bl, ibl, itl, tl], color(0xD4542A)) // left
    face([br, tr, itr, ibr], color(0xC64B22)) // right
    face([tl, itl, itr, tr], color(0xEC7A4C)) // back (catches the light)
    NSGraphicsContext.restoreGraphicsState()

    // Dished top surface.
    let topPath = NSBezierPath(roundedRect: top, xRadius: 70, yRadius: 70)
    NSGradient(colors: [color(0xFFA27A), color(0xF4794A), color(0xE9693B)])!.draw(in: topPath, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    topPath.addClip()
    let dish = NSGradient(starting: color(0xFFFFFF, 0.18), ending: color(0xFFFFFF, 0))!
    dish.draw(fromCenter: NSPoint(x: top.midX, y: top.midY + 40), radius: 0,
              toCenter: NSPoint(x: top.midX, y: top.midY + 40), radius: 210, options: [])
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.25).setStroke()
    topPath.lineWidth = 4
    topPath.stroke()

    // Three little sound arcs off the top-right corner.
    tile.addClip()
    color(0xF5F1EA, 0.9).setStroke()
    for (i, r) in [48.0, 84.0, 120.0].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 772, y: 746), radius: r, startAngle: 12, endAngle: 78)
        arc.lineWidth = 22 - CGFloat(i) * 3
        arc.lineCapStyle = .round
        arc.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Clacky.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: base * scale).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
