import AppKit

/// An app in the quick-launch bar at the top of the switcher (Shift+1…9, 0 opens it, or its own
/// key). Stored by path, plus bundle ID so it can still be found if the app is moved.
struct QuickLaunchApp: Equatable {
    let path: String
    let bundleID: String?
    /// The user's own key for it, as a key token (see `QuickLaunch.isValidKey`): "c" for C,
    /// "⇧c" for Shift+C. Nil uses its position in the bar (Shift+1…9, 0).
    var key: String?

    init(path: String, bundleID: String?, key: String? = nil) {
        (self.path, self.bundleID, self.key) = (path, bundleID, key)
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

    /// The bar before the user has changed it.
    static let defaults = [
        QuickLaunchApp(path: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder"),
        QuickLaunchApp(path: "/System/Applications/Utilities/Activity Monitor.app", bundleID: "com.apple.ActivityMonitor"),
    ]
}

enum QuickLaunch {
    static let shift = "⇧"

    /// Key tokens: a lowercase letter ("c", pressed on its own while the switcher is open) or a
    /// letter or digit with Shift ("⇧c", "⇧1"). Plain digits aren't allowed: they jump to rows.
    static func token(_ char: String, shift: Bool) -> String { (shift ? Self.shift : "") + char }

    static func isValidKey(_ token: String) -> Bool {
        let shifted = token.hasPrefix(shift)
        let char = shifted ? String(token.dropFirst(shift.count)) : token
        guard char.count == 1, let scalar = char.unicodeScalars.first else { return false }
        return ("a"..."z").contains(scalar) || (shifted && ("0"..."9").contains(scalar))
    }

    /// Each app's key token, in order; nil when it has none. Apps with their own key get it;
    /// the rest get their position's Shift+digit (1…9, 0 for the first ten), unless an app's
    /// own key already took it.
    static func keys(_ apps: [QuickLaunchApp]) -> [String?] {
        let own = Set(apps.compactMap(\.key))
        return apps.enumerated().map { i, app in
            if let key = app.key { return key }
            let digit = token(String((i + 1) % 10), shift: true)
            return i < 10 && !own.contains(digit) ? digit : nil
        }
    }

    /// How a key is shown: "C", "⇧C", "⇧1".
    static func label(_ token: String?) -> String? {
        token?.uppercased()
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
