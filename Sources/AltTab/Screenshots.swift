import AltTabCore
import AppKit

/// `AltTab --screenshots <dir>` renders the README screenshots from the real panel and
/// Preferences window, filled with made-up window titles (no real windows are listed).
/// An app may capture its own windows without Screen Recording permission, so each shot
/// shows our window over a gradient backdrop window we also own.
enum Screenshots {
    static func run(outputDirectory: String) {
        let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let backdrop = Backdrop()
        // One panel per shot, whatever the user's all-displays preference is.
        Settings.showOnAllScreensOverride = false
        let panel = SwitcherPanel()
        let demo = demoWindows()
        let pinned: Set<Int> = [0, 1]
        func rows(_ windows: [(WindowInfo, Int)]) -> [SwitcherPanel.Row] {
            windows.enumerated().map { i, pair in
                .init(window: pair.0, number: i < 10 ? String((i + 1) % 10) : nil, isPinned: pinned.contains(pair.1))
            }
        }
        let indexed = demo.enumerated().map { ($1, $0) }

        func shoot(_ name: String, _ render: () -> NSWindow?) {
            guard let window = render() else { return }
            backdrop.cover(window.frame.insetBy(dx: -48, dy: -48), below: window)
            settle(0.6)
            if let image = capture(windowNumber: window.windowNumber, rect: backdrop.frame) {
                write(image, to: out.appendingPathComponent(name))
            }
            window.orderOut(nil)
        }

        shoot("switcher.png") {
            panel.show(rows(indexed), selected: 3, query: "", stayOpen: false, launchers: demoLaunchers())
            return panelWindow(panel)
        }
        shoot("filter.png") {
            let matches = indexed.filter { "\($0.0.title) \($0.0.appName)".lowercased().contains("alttab") }
            panel.show(rows(matches), selected: 0, query: "alttab", stayOpen: true)
            return panelWindow(panel)
        }
        shoot("large-font.png") {
            Settings.fontSizeOverride = 20
            defer { Settings.fontSizeOverride = nil }
            panel.show(rows(Array(indexed.prefix(6))), selected: 2, query: "", stayOpen: false)
            return panelWindow(panel)
        }
        panel.hide()
        shoot("apps.png") {
            let apps = demoApps()
            panel.show(apps.enumerated().map { i, w in .init(window: w, number: String(i + 1), isPinned: i == 0) },
                       selected: 1, query: "", stayOpen: false, placeholder: "Type to filter apps")
            return panelWindow(panel)
        }
        panel.hide()
        shoot("apps-icons.png") {
            let apps = demoApps()
            panel.show(apps.enumerated().map { i, w in .init(window: w, number: String(i + 1), isPinned: i == 0) },
                       selected: 1, query: "", stayOpen: false, placeholder: "Type to filter apps", layout: .icons)
            return panelWindow(panel)
        }
        panel.hide()
        Settings.showOnAllScreensOverride = nil // Preferences shows the real setting
        // Unbundled runs have no app icon; use the repo's for the About tab.
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.png") { NSApp.applicationIconImage = icon }
        let prefs = PreferencesWindow()
        shoot("preferences.png") {
            prefs.show(.general)
            return prefs.window
        }
        shoot("quick-launch.png") {
            prefs.show(.quickLaunch)
            return prefs.window
        }
        shoot("about.png") {
            prefs.show(.about)
            return prefs.window
        }
        backdrop.orderOut(nil)
        print("Wrote screenshots to \(out.path)")
    }

    private static func panelWindow(_ panel: SwitcherPanel) -> NSWindow? {
        NSApp.window(withWindowNumber: panel.windowNumber)
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func demoWindows() -> [WindowInfo] {
        func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
        let sublime = FileManager.default.fileExists(atPath: "/Applications/Sublime Text.app")
            ? ("/Applications/Sublime Text.app", "Sublime Text") : ("/System/Applications/TextEdit.app", "TextEdit")
        let items: [(String, String, String)] = [
            (sublime.0, sublime.1, "notes.md — scratch"),
            ("/System/Applications/Utilities/Terminal.app", "Terminal", "swift build — AltTab"),
            (sublime.0, sublime.1, "SwitcherPanel.swift — AltTab"),
            ("/Applications/Safari.app", "Safari", "Pull requests · sr3d/AltTab"),
            (sublime.0, sublime.1, "README.md — AltTab"),
            ("/System/Library/CoreServices/Finder.app", "Finder", "Downloads"),
            ("/System/Applications/Notes.app", "Notes", "Weekly plan"),
            ("/System/Applications/Mail.app", "Mail", "Inbox"),
            ("/System/Applications/Calendar.app", "Calendar", "Calendar"),
            ("/System/Applications/Messages.app", "Messages", "Messages"),
            ("/System/Applications/Music.app", "Music", "Music"),
            ("/System/Applications/Preview.app", "Preview", "diagram.png"),
            ("/System/Applications/Utilities/Activity Monitor.app", "Activity Monitor", "Activity Monitor"),
            ("/System/Applications/System Settings.app", "System Settings", "Displays"),
        ]
        // App icons can arrive as a placeholder that fills in asynchronously; ask once, let
        // them load, then ask again.
        items.forEach { _ = icon($0.0) }
        settle(2)
        return items.enumerated().map { i, item in
            WindowInfo(id: CGWindowID(1000 + i), pid: 0, element: nil, title: item.2, appName: item.1, icon: icon(item.0))
        }
    }

    /// Quick-launch bar items for the main screenshot.
    private static func demoLaunchers() -> [SwitcherPanel.Launcher] {
        [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/Safari.app",
            "/System/Applications/Utilities/Terminal.app",
            "/System/Applications/Utilities/Activity Monitor.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
        ].filter { FileManager.default.fileExists(atPath: $0) }.map { path in
            let name = FileManager.default.displayName(atPath: path)
            return .init(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, icon: NSWorkspace.shared.icon(forFile: path))
        }
    }

    private static func demoApps() -> [WindowInfo] {
        let items: [(String, String, String)] = [
            ("/Applications/Sublime Text.app", "Sublime Text", "12 windows"),
            ("/System/Applications/Utilities/Terminal.app", "Terminal", "3 windows"),
            ("/Applications/Safari.app", "Safari", "2 windows"),
            ("/System/Library/CoreServices/Finder.app", "Finder", "1 window"),
            ("/System/Applications/Mail.app", "Mail", "1 window"),
            ("/System/Applications/Music.app", "Music", "Music"),
        ].filter { FileManager.default.fileExists(atPath: $0.0) }
        items.forEach { _ = NSWorkspace.shared.icon(forFile: $0.0) }
        settle(1)
        return items.enumerated().map { i, item in
            WindowInfo(id: CGWindowID(2000 + i), pid: 0, element: nil, title: item.1, appName: item.2,
                       icon: NSWorkspace.shared.icon(forFile: item.0))
        }
    }

    // CGWindowListCreateImage is unavailable in the macOS 15 SDK, so resolve it at runtime.
    // It still works for capturing our own windows without Screen Recording permission.
    private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: CreateImageFn.self)
    }()

    private static func capture(windowNumber: Int, rect: NSRect) -> CGImage? {
        // AppKit rects are bottom-left based; CG global coordinates are top-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        let options = CGWindowListOption.optionOnScreenBelowWindow.union(.optionIncludingWindow).rawValue
        let imageOptions = CGWindowImageOption.bestResolution.rawValue
        return createImage?(cgRect, options, UInt32(windowNumber), imageOptions)?.takeRetainedValue()
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("  \(url.lastPathComponent) \(image.width)×\(image.height)")
    }
}

/// Opaque gradient "wallpaper" placed directly under the window being captured.
private final class Backdrop: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        contentView = GradientView()
    }

    func cover(_ rect: NSRect, below window: NSWindow) {
        level = window.level
        setFrame(rect, display: true)
        order(.below, relativeTo: window.windowNumber)
    }

    private final class GradientView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [NSColor(red: 0.20, green: 0.16, blue: 0.55, alpha: 1),
                                NSColor(red: 0.12, green: 0.42, blue: 0.62, alpha: 1),
                                NSColor(red: 0.10, green: 0.55, blue: 0.50, alpha: 1)])?.draw(in: bounds, angle: -35)
        }
    }
}
