import AppKit

/// A bookmark in the Quick Jumps box beside the switcher: a folder, a file or a web address.
/// Clicking it opens it the way Finder would (a folder in Finder, a file in its app, a URL in
/// the default browser). Files are stored by path.
struct QuickJump: Equatable {
    let url: URL
    /// The user's own name for it; nil uses the file's name or the URL's host.
    var customName: String?

    init(url: URL, name: String? = nil) {
        self.url = url
        customName = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// A web address typed by hand: "example.com/x" gets https://. Nil if it isn't a usable URL.
    init?(typed text: String, name: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.scheme != nil,
              url.isFileURL || url.host?.isEmpty == false || url.scheme == "mailto" else { return nil }
        self.init(url: url, name: name)
    }

    var name: String {
        if let customName { return customName }
        if url.isFileURL { return FileManager.default.displayName(atPath: url.path) }
        return url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
    }

    /// What it points at, for tooltips and the Preferences list: a ~-relative path or the URL.
    var detail: String {
        url.isFileURL ? (url.path as NSString).abbreviatingWithTildeInPath : url.absoluteString
    }

    /// False for a file or folder that's been moved or deleted.
    var exists: Bool { !url.isFileURL || FileManager.default.fileExists(atPath: url.path) }

    var icon: NSImage { QuickJumps.icon(for: self) }

    /// The list before the user has changed it.
    static let defaults = [
        QuickJump(url: FileManager.default.homeDirectoryForCurrentUser),
        QuickJump(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")),
    ]
}

enum QuickJumps {
    /// Opens the folder, file or URL.
    static func open(_ jump: QuickJump) {
        guard jump.exists else {
            NSLog("AltTab: quick jump not found: \(jump.url.path)")
            NSSound.beep()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(jump.url, configuration: config) { _, error in
            if let error { NSLog("AltTab: quick jump failed for \(jump.url): \(error)") }
        }
    }

    // Icons by URL: a file's own icon, or for a web address the app that opens it (the default
    // browser). Kept as NSWorkspace hands them back, like Quick Launch's. Main thread only.
    private static var icons: [URL: NSImage] = [:]

    static func icon(for jump: QuickJump) -> NSImage {
        if let hit = icons[jump.url] { return hit }
        let image: NSImage
        if jump.url.isFileURL {
            image = NSWorkspace.shared.icon(forFile: jump.url.path)
        } else if let app = NSWorkspace.shared.urlForApplication(toOpen: jump.url) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else {
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
        icons[jump.url] = image
        return image
    }

    /// Loads icons ahead of time so the switcher doesn't pay for them.
    static func warm() {
        Settings.quickJumps.forEach { _ = icon(for: $0) }
    }
}
