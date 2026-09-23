import AppKit

/// App icons, loaded once per app and pre-rendered to a single bitmap.
/// `NSRunningApplication.icon` isn't reliably kept between switcher openings, and reloading it
/// costs several ms per app (100+ ms for a full list); drawing the full multi-size icon is slow
/// too. Main thread only.
public enum AppIcons {
    private static var cache: [pid_t: NSImage] = [:]
    /// 192 pt @2x: covers the largest icon tile at big font sizes.
    private static let pixels = 384

    public static func icon(for app: NSRunningApplication) -> NSImage? {
        let pid = app.processIdentifier
        if let hit = cache[pid] { return hit }
        guard let source = app.icon else { return nil }
        let image = rasterize(source)
        cache[pid] = image
        return image
    }

    /// Loads icons ahead of time so the first switcher opening doesn't pay for them.
    public static func warm(_ apps: [NSRunningApplication]) {
        for app in apps where app.activationPolicy != .prohibited { _ = icon(for: app) }
    }

    /// Drops a quit app's icon (pids get reused).
    public static func forget(_ pid: pid_t) {
        cache[pid] = nil
    }

    private static func rasterize(_ source: NSImage) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: pixels / 2, height: pixels / 2)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
