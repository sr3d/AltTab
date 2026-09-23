import AppKit

/// An app in the quick-launch bar at the top of the switcher (Shift+1…9, 0 opens it).
/// Stored by path, plus bundle ID so it can still be found if the app is moved.
struct QuickLaunchApp: Equatable {
    let path: String
    let bundleID: String?

    init(path: String, bundleID: String?) {
        (self.path, self.bundleID) = (path, bundleID)
    }

    /// Nil unless `url` is an app bundle.
    init?(url: URL) {
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else { return nil }
        self.init(path: url.path, bundleID: bundle.bundleIdentifier)
    }

    var name: String {
        let name = FileManager.default.displayName(atPath: location?.path ?? path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Where the app is now: its saved path, or wherever its bundle ID lives if it moved.
    var location: URL? {
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var icon: NSImage { QuickLaunch.icon(for: self) }
}

enum QuickLaunch {
    /// Keyboard shortcut label for the nth (0-based) item: "⇧1"…"⇧9", "⇧0"; nil past the tenth.
    static func shortcut(_ index: Int) -> String? {
        index < 10 ? "⇧\((index + 1) % 10)" : nil
    }

    /// Opens (or brings forward, if running) the app.
    static func open(_ app: QuickLaunchApp) {
        guard let url = app.location else {
            NSLog("AltTab: quick launch app not found: \(app.path)")
            NSSound.beep()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("AltTab: quick launch failed for \(url.path): \(error)") }
        }
    }

    // Icons by path. NSWorkspace can hand back a placeholder that fills in asynchronously,
    // so keep its NSImage (which updates itself) rather than a rendered copy. Main thread only.
    private static var icons: [String: NSImage] = [:]

    static func icon(for app: QuickLaunchApp) -> NSImage {
        if let hit = icons[app.path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: app.location?.path ?? app.path)
        icons[app.path] = image
        return image
    }

    /// Loads icons ahead of time so the switcher doesn't pay for them.
    static func warm() {
        Settings.quickLaunchApps.forEach { _ = icon(for: $0) }
    }
}
