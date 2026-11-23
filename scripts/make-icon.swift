// Draws the RemoteMirror app icon and writes packaging/AppIcon.icns.
// Run: swift scripts/make-icon.swift   (needs only the Command Line Tools)
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024           // design on a 1024 grid
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Background: macOS-style rounded square with a blue-to-teal gradient.
    let bg = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.36, blue: 0.86, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.72, blue: 0.80, alpha: 1))!.draw(in: bg, angle: -60)

    // iMac: screen with bezel, chin and stand.
    let white = NSColor(white: 1, alpha: 0.96)
    white.setFill()
    NSBezierPath(roundedRect: r(250, 400, 524, 380), xRadius: 34 * s, yRadius: 34 * s).fill()       // body
    NSColor(srgbRed: 0.08, green: 0.20, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(282, 470, 460, 278), xRadius: 14 * s, yRadius: 14 * s).fill()       // screen
    white.setFill()
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 465 * s, y: 400 * s)); stand.line(to: NSPoint(x: 559 * s, y: 400 * s))
    stand.line(to: NSPoint(x: 585 * s, y: 300 * s)); stand.line(to: NSPoint(x: 439 * s, y: 300 * s)); stand.close()
    stand.fill()
    NSBezierPath(roundedRect: r(400, 282, 224, 26), xRadius: 13 * s, yRadius: 13 * s).fill()        // foot

    // Mirrored MacBook shown on the iMac screen: a small laptop glyph.
    NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(415, 545, 194, 128), xRadius: 10 * s, yRadius: 10 * s).fill()       // lid
    NSBezierPath(roundedRect: r(385, 525, 254, 20), xRadius: 8 * s, yRadius: 8 * s).fill()          // base

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("AppIcon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(root.path)/AppIcon.icns" : "iconutil failed")
