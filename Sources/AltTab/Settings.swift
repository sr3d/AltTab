import Foundation

/// User preferences, stored in UserDefaults (com.sr3d.AltTab).
enum Settings {
    static let fontSizeRange: ClosedRange<Double> = 11...28
    static let defaultFontSize: Double = 14
    /// Temporary size that doesn't touch saved preferences (used by screenshot rendering).
    static var fontSizeOverride: CGFloat?
    /// Temporary all-displays choice that doesn't touch saved preferences (screenshot rendering).
    static var showOnAllScreensOverride: Bool?

    private static let defaults = UserDefaults.standard

    /// Point size for the switcher list; rows, icons and the filter bar scale with it.
    static var fontSize: CGFloat {
        get {
            if let fontSizeOverride { return fontSizeOverride }
            let stored = defaults.double(forKey: "fontSize")
            return CGFloat(stored == 0 ? defaultFontSize : min(max(stored, fontSizeRange.lowerBound), fontSizeRange.upperBound))
        }
        set { defaults.set(Double(newValue), forKey: "fontSize") }
    }

    /// Cmd+Tab opens AltTab's switcher instead of the macOS one.
    static var commandTabTakeover: Bool {
        get { defaults.bool(forKey: "commandTabTakeover") }
        set { defaults.set(newValue, forKey: "commandTabTakeover") }
    }

    /// What AltTab's Cmd+Tab lists: windows (like Option+Tab, the default) or running apps.
    static var commandTabMode: SwitcherMode {
        get { defaults.string(forKey: "commandTabMode").flatMap(SwitcherMode.init(rawValue:)) ?? .windows }
        set { defaults.set(newValue.rawValue, forKey: "commandTabMode") }
    }

    /// App switcher layout: a vertical list (default) or a horizontal strip of icons like macOS.
    static var appSwitcherLayout: SwitcherLayout {
        get { defaults.string(forKey: "appSwitcherLayout").flatMap(SwitcherLayout.init(rawValue:)) ?? .list }
        set { defaults.set(newValue.rawValue, forKey: "appSwitcherLayout") }
    }

    /// App switcher: bring all of the chosen app's windows forward (like macOS), or only its
    /// most recently used window.
    static var appSwitchBringsAllWindows: Bool {
        get { defaults.object(forKey: "appSwitchBringsAllWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "appSwitchBringsAllWindows") }
    }

    /// Apps in the quick-launch bar, in order.
    static var quickLaunchApps: [QuickLaunchApp] {
        get {
            // Never set: start with Finder and Activity Monitor. An emptied list stays empty.
            guard let stored = defaults.array(forKey: "quickLaunchApps") as? [[String: String]] else {
                return QuickLaunchApp.defaults
            }
            return stored.compactMap { d in
                d["path"].map { QuickLaunchApp(path: $0, bundleID: d["bundleID"], key: d["key"]) }
            }
        }
        set {
            defaults.set(newValue.map { app in
                var d = ["path": app.path]
                if let id = app.bundleID { d["bundleID"] = id }
                if let key = app.key { d["key"] = key }
                return d
            }, forKey: "quickLaunchApps")
        }
    }

    /// Show the switcher on every display, or only on the one under the mouse.
    static var showOnAllScreens: Bool {
        get { showOnAllScreensOverride ?? defaults.object(forKey: "showOnAllScreens") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showOnAllScreens") }
    }
}
