// Renders Resources/AppIcon.icns: two stacked windows with the front one raised, plus ⌥⇥.
// Usage: swift scripts/make-icon.swift   (from the repo root)
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024 // design on a 1024 grid

    // Background squircle (Apple's grid: 824pt body inset 100pt).
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(red: 0.13, green: 0.10, blue: 0.42, alpha: 1)])!.draw(in: bg, angle: -90)

    func window(_ rect: NSRect, fill: NSColor, bar: NSColor, dots: Bool) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 30 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: 36 * s, yRadius: 36 * s)
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        bar.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 70 * s, width: rect.width, height: 70 * s).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard dots else { return }
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + (34 + CGFloat(i) * 46) * s, y: rect.maxY - 51 * s,
                                        width: 32 * s, height: 32 * s)).fill()
        }
    }

    // Back window (dimmed) and front window (raised), offset diagonally.
    window(NSRect(x: 190 * s, y: 380 * s, width: 470 * s, height: 360 * s),
           fill: NSColor.white.withAlphaComponent(0.35), bar: NSColor.white.withAlphaComponent(0.25), dots: false)
    window(NSRect(x: 360 * s, y: 250 * s, width: 480 * s, height: 370 * s),
           fill: .white, bar: NSColor(white: 0.88, alpha: 1), dots: true)

    // Key hint on the front window's content area.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 150 * s, weight: .bold),
        .foregroundColor: NSColor(red: 0.25, green: 0.20, blue: 0.75, alpha: 1),
        .paragraphStyle: para,
    ]
    ("⌥⇥" as NSString).draw(in: NSRect(x: 360 * s, y: 285 * s, width: 480 * s, height: 200 * s), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns").path
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
