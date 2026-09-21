import AppKit
import ApplicationServices

public struct WindowInfo {
    public let id: CGWindowID
    public let pid: pid_t
    /// nil when the app's AX windows haven't been cached yet; focusing still works via SkyLight.
    public let element: AXUIElement?
    public let title: String
    public let appName: String
    public let icon: NSImage?

    public init(id: CGWindowID, pid: pid_t, element: AXUIElement?, title: String, appName: String, icon: NSImage?) {
        (self.id, self.pid, self.element, self.title, self.appName, self.icon) = (id, pid, element, title, appName, icon)
    }
}

/// An on-screen window as reported by the WindowServer (cheap: a few ms for all windows).
public struct ScreenWindow {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
}

/// AX view of one app's windows. `windows` holds switchable windows; `rejected` holds IDs the
/// app reported with a non-standard subrole (palettes, popups) so they can be skipped.
public struct AXSnapshot {
    public var windows: [CGWindowID: (element: AXUIElement, title: String)] = [:]
    public var rejected: Set<CGWindowID> = []
}

public enum WindowList {
    private static let ownerDenylist: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center"]
    private static let allowedSubroles: Set<String> = [kAXStandardWindowSubrole as String, kAXDialogSubrole as String]

    /// On-screen layer-0 windows on the current Space, front-to-back (z-order).
    public static func onScreen() -> [ScreenWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPid = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            if ownerDenylist.contains(owner) { return nil }
            if let b = info[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) < 50 || (b["Height"] ?? 0) < 50 { return nil }
            return ScreenWindow(id: id, pid: pid, ownerName: owner)
        }
    }

    /// Combines on-screen windows with cached AX snapshots. Windows whose app has no snapshot
    /// yet (or that are newer than it) are included with the app name as title.
    public static func build(_ screen: [ScreenWindow], snapshots: [pid_t: AXSnapshot]) -> [WindowInfo] {
        var apps: [pid_t: NSRunningApplication?] = [:]
        return screen.compactMap { w in
            let snap = snapshots[w.pid]
            if snap?.rejected.contains(w.id) == true { return nil }
            let app = apps[w.pid] ?? NSRunningApplication(processIdentifier: w.pid)
            apps[w.pid] = app
            guard app?.activationPolicy != .prohibited else { return nil }
            let appName = app?.localizedName ?? w.ownerName
            let ax = snap?.windows[w.id]
            let title = ax?.title ?? ""
            return WindowInfo(id: w.id, pid: w.pid, element: ax?.element,
                              title: title.isEmpty ? appName : title, appName: appName, icon: app?.icon)
        }
    }

    /// Reorders by most-recent focus; windows never seen focused keep z-order after them.
    public static func order(_ windows: [WindowInfo], mru: [CGWindowID]) -> [WindowInfo] {
        let rank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return windows.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (ra?, rb?): return ra < rb
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Synchronous convenience for tools: z-order with AX titles. Slow (AX IPC per app).
    public static func current(timeout: Float = 2) -> [WindowInfo] {
        let screen = onScreen()
        var snaps: [pid_t: AXSnapshot] = [:]
        for pid in Set(screen.map(\.pid)) { snaps[pid] = snapshot(pid: pid, timeout: timeout) }
        return build(screen, snapshots: snaps).filter { $0.element != nil }
    }

    /// AX windows for one app. Can take seconds for busy apps, so call it off the main thread.
    public static func snapshot(pid: pid_t, timeout: Float = 2) -> AXSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        var snap = AXSnapshot()
        for el in elements {
            guard let wid = windowID(of: el) else { continue }
            if let sub = stringAttr(el, kAXSubroleAttribute), allowedSubroles.contains(sub) {
                snap.windows[wid] = (el, stringAttr(el, kAXTitleAttribute) ?? "")
            } else {
                snap.rejected.insert(wid)
            }
        }
        return snap
    }

    static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
