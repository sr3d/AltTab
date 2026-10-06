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

        // `render` returns the windows to capture, frontmost first (the panel, then its group boxes).
        func shoot(_ name: String, _ render: () -> [NSWindow]) {
            let windows = render()
            guard let top = windows.first, let bottom = windows.last else { return }
            for (upper, lower) in zip(windows, windows.dropFirst()) { lower.order(.below, relativeTo: upper.windowNumber) }
            let frame = windows.dropFirst().reduce(top.frame) { $0.union($1.frame) }
            backdrop.cover(frame.insetBy(dx: -48, dy: -48), below: bottom)
            settle(0.6)
            if let image = capture(windowNumber: top.windowNumber, rect: backdrop.frame) {
                write(image, to: out.appendingPathComponent(name))
            }
            windows.forEach { $0.orderOut(nil) }
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
        shoot("groups.png") {
            panel.show(rows(indexed), selected: 3, query: "", stayOpen: false, launchers: demoLaunchers())
            panel.showGroups(demoGroups(demo))
            panel.showJumps(demoJumps())
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
            return prefs.window.map { [$0] } ?? []
        }
        shoot("quick-launch.png") {
            prefs.show(.quickLaunch)
            return prefs.window.map { [$0] } ?? []
        }
        shoot("quick-jumps.png") {
            prefs.show(.quickJumps)
            return prefs.window.map { [$0] } ?? []
        }
        shoot("about.png") {
            prefs.show(.about)
            return prefs.window.map { [$0] } ?? []
        }
        backdrop.orderOut(nil)
        print("Wrote screenshots to \(out.path)")
    }

    private static func panelWindow(_ panel: SwitcherPanel) -> [NSWindow] {
        [NSApp.window(withWindowNumber: panel.windowNumber), panel.groupsWindow, panel.jumpsWindow].compactMap { $0 }
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

    /// Quick-launch bar items for the main screenshot; Calendar shows a custom key (C).
    private static func demoLaunchers() -> [SwitcherPanel.Launcher] {
        let apps = [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/Safari.app",
            "/System/Applications/Utilities/Terminal.app",
            "/System/Applications/Utilities/Activity Monitor.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
        ].filter { FileManager.default.fileExists(atPath: $0) }.map { path in
            QuickLaunchApp(path: path, bundleID: nil, key: path.hasSuffix("Calendar.app") ? "c" : nil)
        }
        return zip(apps, QuickLaunch.keys(apps)).map { app, key in
            .init(name: app.name, icon: NSWorkspace.shared.icon(forFile: app.path), shortcut: QuickLaunch.label(key))
        }
    }

    /// Two window groups built from the demo windows, with drawn stand-ins for window previews
    /// (real captures would need Screen Recording permission and would change run to run).
    private static func demoGroups(_ demo: [WindowInfo]) -> [SwitcherPanel.Group] {
        func member(_ i: Int, _ look: PreviewLook) -> SwitcherPanel.Member {
            let w = demo[i]
            return .init(id: w.id, caption: w.title, title: "\(w.title)  —  \(w.appName)", icon: w.icon, preview: demoPreview(look))
        }
        return [
            .init(name: "Group 1", members: [member(2, .editor), member(1, .terminal), member(3, .browser)]),
            .init(name: "Group 2", members: [member(7, .mail), member(6, .notes),
                                             // A window that isn't open (after a reboot): a placeholder.
                                             .init(id: 0, caption: "Standup notes", title: "Standup notes  —  TextEdit",
                                                   icon: NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app"),
                                                   preview: nil, isOpen: false)]),
        ]
    }

    /// Quick Jumps for the groups screenshot: folders, a file and a web page.
    private static func demoJumps() -> [SwitcherPanel.Jump] {
        let folder = NSWorkspace.shared.icon(for: .folder)
        let home = NSWorkspace.shared.icon(forFile: NSHomeDirectory())
        let downloads = NSWorkspace.shared.icon(forFile: NSHomeDirectory() + "/Downloads")
        let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        return [
            .init(name: "Home", detail: "~", icon: home),
            .init(name: "Downloads", detail: "~/Downloads", icon: downloads),
            .init(name: "AltTab", detail: "~/projects/AltTab", icon: folder),
            .init(name: "Weekly plan.md", detail: "~/Documents/Weekly plan.md", icon: NSWorkspace.shared.icon(for: .plainText)),
            .init(name: "AltTab on GitHub", detail: "https://github.com/sr3d/AltTab", icon: safari),
        ]
    }

    private enum PreviewLook { case editor, terminal, browser, mail, notes }

    /// A simplified window: title bar with traffic lights over content that suggests the app.
    private static func demoPreview(_ look: PreviewLook) -> NSImage {
        NSImage(size: NSSize(width: 320, height: 200), flipped: true) { rect in
            let dark = look == .editor || look == .terminal
            let background: NSColor = switch look {
            case .editor: NSColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1)
            case .terminal: NSColor(white: 0.08, alpha: 1)
            case .notes: NSColor(red: 1, green: 0.99, blue: 0.93, alpha: 1)
            case .browser, .mail: .white
            }
            background.setFill()
            rect.fill()
            NSColor(white: dark ? 0.24 : 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 22).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 9 + CGFloat(i) * 15, y: 6, width: 10, height: 10)).fill()
            }
            let widths: [CGFloat] = [0.62, 0.38, 0.8, 0.5, 0.72, 0.27, 0.66, 0.44, 0.58, 0.33, 0.75, 0.48, 0.6]
            func lines(x: CGFloat, y: CGFloat, width: CGFloat, colors: [NSColor], step: CGFloat = 13) {
                var y = y, i = 0
                while y < rect.height - 10 {
                    colors[i % colors.count].setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width * widths[i % widths.count], height: 6),
                                 xRadius: 3, yRadius: 3).fill()
                    y += step
                    i += 1
                }
            }
            switch look {
            case .editor:
                lines(x: 16, y: 34, width: 260, colors: [.systemPink, .systemTeal, NSColor(white: 0.75, alpha: 1), .systemOrange, .systemPurple])
            case .terminal:
                lines(x: 12, y: 32, width: 220, colors: [.systemGreen, NSColor(white: 0.8, alpha: 1), NSColor(white: 0.8, alpha: 1)], step: 12)
            case .browser:
                NSColor(white: 0.96, alpha: 1).setFill()
                NSRect(x: 0, y: 22, width: rect.width, height: 20).fill()
                NSColor.systemBlue.withAlphaComponent(0.85).setFill()
                NSRect(x: 16, y: 54, width: 150, height: 12).fill()
                lines(x: 16, y: 78, width: 280, colors: [NSColor(white: 0.78, alpha: 1)])
            case .mail:
                NSColor(white: 0.95, alpha: 1).setFill()
                NSRect(x: 0, y: 22, width: 110, height: rect.height - 22).fill()
                NSColor.systemBlue.withAlphaComponent(0.25).setFill()
                NSRect(x: 0, y: 34, width: 110, height: 26).fill()
                lines(x: 10, y: 40, width: 90, colors: [NSColor(white: 0.6, alpha: 1), NSColor(white: 0.78, alpha: 1)])
                lines(x: 124, y: 36, width: 180, colors: [NSColor(white: 0.45, alpha: 1), NSColor(white: 0.78, alpha: 1)])
            case .notes:
                lines(x: 18, y: 36, width: 270, colors: [NSColor(white: 0.35, alpha: 1), NSColor(white: 0.7, alpha: 1)], step: 15)
            }
            return true
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

    private static func capture(windowNumber: Int, rect: NSRect) -> CGImage? {
        // AppKit rects are bottom-left based; CG global coordinates are top-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        return WindowThumbnail.image(rect: cgRect, options: [.optionOnScreenBelowWindow, .optionIncludingWindow],
                                     window: CGWindowID(windowNumber), imageOptions: .bestResolution)
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
