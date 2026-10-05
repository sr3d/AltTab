import AltTabCore
import AppKit

/// One window in a group. It remembers the window's app and title, so the group survives the
/// window closing and AltTab relaunching (rebuilds, reboots). While the window is open,
/// `window` holds it; otherwise the member is a placeholder until a window of the same app with
/// the same title shows up again.
struct GroupMember: Codable {
    var title: String
    var appName: String
    var bundleID: String?
    var appPath: String?
    /// The window last connected to. Window IDs outlive an AltTab relaunch but not a reboot.
    var windowID: CGWindowID?
    /// The open window; nil for a placeholder. Not saved.
    var window: WindowInfo?

    private enum CodingKeys: String, CodingKey { case title, appName, bundleID, appPath, windowID }

    init(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        title = window.title
        appName = window.appName
        bundleID = app?.bundleIdentifier
        appPath = app?.bundleURL?.path
        windowID = window.id
        self.window = window
    }

    /// The app, for a placeholder's icon and for opening it.
    var app: QuickLaunchApp? { appPath.map { QuickLaunchApp(path: $0, bundleID: bundleID) } }

    /// Whether `pid` is this member's app.
    func isApp(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let bundleID { return app.bundleIdentifier == bundleID }
        return app.localizedName == appName
    }
}

/// Windows dragged together into a named group, shown as boxes beside the switcher so any of
/// them is one click away. Saved in UserDefaults on every change.
struct WindowGroup: Codable {
    var name: String
    var members: [GroupMember]
}

/// The groups, in creation order. A window is in at most one group, and a group goes away when
/// its last member is removed.
struct WindowGroups {
    private(set) var groups: [WindowGroup] = []
    /// The last good preview of each open member, by window ID.
    private(set) var thumbnails: [CGWindowID: NSImage] = [:]

    private static let key = "windowGroups"

    /// The saved groups, all members as placeholders until `reconnect` finds their windows.
    static func load() -> WindowGroups {
        var loaded = WindowGroups()
        if let data = UserDefaults.standard.data(forKey: key),
           let groups = try? JSONDecoder().decode([WindowGroup].self, from: data) {
            loaded.groups = groups
        }
        return loaded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Every member's last known window ID (open or not), for checking which still exist.
    var windowIDs: [CGWindowID] { groups.flatMap { $0.members.compactMap(\.windowID) } }

    /// The window IDs of open members.
    var openIDs: [CGWindowID] { groups.flatMap { $0.members.compactMap(\.window?.id) } }

    func member(_ group: Int, _ member: Int) -> GroupMember? {
        guard groups.indices.contains(group), groups[group].members.indices.contains(member) else { return nil }
        return groups[group].members[member]
    }

    /// Starts a group holding `window`, named "Group n" with the lowest free n.
    mutating func newGroup(with window: WindowInfo) {
        detach(window.id)
        let names = Set(groups.map(\.name))
        let n = (1...).first { !names.contains("Group \($0)") }!
        groups.append(WindowGroup(name: "Group \(n)", members: [GroupMember(window)]))
        save()
    }

    /// Adds `window` to the group at `index`, moving it out of any other group.
    mutating func add(_ window: WindowInfo, to index: Int) {
        guard groups.indices.contains(index), !groups[index].members.contains(where: { $0.windowID == window.id }) else { return }
        // Detaching can delete an emptied group and shift the indices, so find the target by name.
        let name = groups[index].name
        detach(window.id)
        if let target = groups.firstIndex(where: { $0.name == name }) { groups[target].members.append(GroupMember(window)) }
        save()
    }

    mutating func remove(_ member: Int, from group: Int) {
        guard let removed = self.member(group, member) else { return }
        groups[group].members.remove(at: member)
        if let id = removed.windowID { thumbnails[id] = nil }
        groups.removeAll { $0.members.isEmpty }
        save()
    }

    /// Matches members to the windows open now. `existing` maps every member's last window ID
    /// that still exists (on any Space) to its owner's pid; `windows` are the windows listed now
    /// (with titles); `make` builds a `WindowInfo` for an existing ID that isn't listed (another
    /// Space). A member whose window is gone becomes a placeholder; a placeholder takes a listed
    /// window of its app with the same title.
    mutating func reconnect(existing: [CGWindowID: pid_t], windows: [WindowInfo],
                            make: (CGWindowID, pid_t) -> WindowInfo?) {
        let before = try? JSONEncoder().encode(groups)
        let listed = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // By ID first. IDs are reused after a reboot, so the window must also be the member's app's.
        for g in groups.indices {
            for m in groups[g].members.indices {
                var member = groups[g].members[m]
                if let id = member.windowID, let pid = existing[id], member.isApp(pid) {
                    // A listed copy has the newest title; keep an AX element we already have, though.
                    let fresh = listed[id].flatMap { $0.element != nil || member.window?.element == nil ? $0 : nil }
                    member.window = fresh ?? member.window ?? make(id, pid)
                } else {
                    member.window = nil
                }
                if member.window == nil, let id = member.windowID {
                    thumbnails[id] = nil
                    member.windowID = nil
                }
                groups[g].members[m] = member
            }
        }
        // Then placeholders by app and title, each window going to one member at most.
        var taken = Set(openIDs)
        for g in groups.indices {
            for m in groups[g].members.indices where groups[g].members[m].window == nil {
                let member = groups[g].members[m]
                guard let match = windows.first(where: { !taken.contains($0.id) && $0.title == member.title && member.isApp($0.pid) })
                else { continue }
                groups[g].members[m].window = match
                groups[g].members[m].windowID = match.id
                taken.insert(match.id)
            }
        }
        // Keep the remembered titles current (a browser window's title follows its page). A
        // window whose title isn't known yet lists its app name instead; don't save that.
        for g in groups.indices {
            for m in groups[g].members.indices {
                guard let window = groups[g].members[m].window, window.element != nil || window.title != window.appName else { continue }
                groups[g].members[m].title = window.title
            }
        }
        let after = try? JSONEncoder().encode(groups)
        if after != before { save() }
    }

    /// Keeps the last good preview: a window that can't be captured right now (minimized) keeps its old one.
    mutating func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        guard openIDs.contains(id) else { return }
        thumbnails[id] = image
    }

    private mutating func detach(_ id: CGWindowID) {
        for i in groups.indices { groups[i].members.removeAll { $0.windowID == id } }
        groups.removeAll { $0.members.isEmpty }
    }
}
