import AltTabCore
import AppKit

/// What the switcher lists: windows (Option+Tab) or running apps (Cmd+Tab, when enabled).
enum SwitcherMode: String { case windows, apps }

/// Ties the hotkey to the window/app list, panel and focuser.
/// Quick tap switches to the previous item; holding the modifier shows the panel after a short delay.
/// While open: pins sit at the top, rows are numbered 1-9, 0 for direct jumps, typing filters.
final class Switcher {
    private let tracker: WindowTracker
    private let panel = SwitcherPanel()
    private var mode = SwitcherMode.windows
    // In app mode each row is a WindowInfo whose `id` is the app's pid and whose `appName`
    // holds a window-count subtitle, so the list, pins and panel code are shared.
    private var all: [WindowInfo] = []        // MRU order for this session
    private var visible: [WindowInfo] = []    // pinned first, then the rest, filtered
    private var selectedID: CGWindowID?       // by ID so pinning/filtering keeps the selection
    /// Where the keyboard is: the list (the selected row), the filter bar, or a quick-launch
    /// icon. Shift+Tab climbs from the first row to the filter, then to the first icon.
    private enum Focus: Equatable { case list, filter, launcher(Int) }
    private var focus = Focus.list
    private var query = ""
    private var stayOpen = false
    private var windowPins: [CGWindowID] = [] // session-lifetime, in pin order
    private var appPins: [CGWindowID] = []
    private var pinned: [CGWindowID] {
        get { mode == .windows ? windowPins : appPins }
        set { if mode == .windows { windowPins = newValue } else { appPins = newValue } }
    }
    private var launchers: [QuickLaunchApp] = [] // quick-launch bar, read at start
    private var launcherItems: [SwitcherPanel.Launcher] = []
    private var launcherKeys: [String?] = []     // each launcher's Shift+key
    private var showTimer: Timer?
    private var outsideClickMonitor: Any?
    /// Long enough that a quick tap doesn't flash the panel. The panel is built right away and
    /// only revealed when this runs out, so it appears as soon as the delay ends.
    private let showDelay: TimeInterval = 0.05
    /// Called whenever the switcher finishes so the hotkey returns to idle.
    var onDismiss: (() -> Void)?
    /// Called when the panel switches to stay-open mode on its own (mouse use), so the
    /// hotkey stops treating an Option release as "switch now".
    var onStayOpen: (() -> Void)?

    init(tracker: WindowTracker) {
        self.tracker = tracker
        // Any mouse use keeps the panel open, so releasing Option mid-click/drag doesn't switch.
        panel.onHighlight = { [weak self] index in
            guard let self, visible.indices.contains(index) else { return }
            focus = .list
            selectedID = visible[index].id
            enterStayOpen()
            render()
        }
        panel.onChoose = { [weak self] index in
            guard let self, visible.indices.contains(index) else { return }
            finish(focusing: visible[index])
        }
        panel.onTogglePin = { [weak self] index in
            guard let self, visible.indices.contains(index) else { return }
            enterStayOpen()
            togglePin(visible[index].id)
        }
        panel.onHeaderClick = { [weak self] in self?.enterStayOpen() }
        panel.onHover = { [weak self] index in
            guard let self, visible.indices.contains(index), focus != .list || visible[index].id != selectedID else { return }
            focus = .list
            selectedID = visible[index].id
            render()
        }
        panel.onScroll = { [weak self] delta in
            self?.focus = .list
            self?.move(delta)
        }
        panel.onLaunch = { [weak self] in self?.launch($0) }
        panel.onMovePin = { [weak self] from, to in
            guard let self, visible.indices.contains(from), visible.indices.contains(to) else { return }
            movePin(visible[from].id, to: visible[to].id)
        }
    }

    private var isOpen: Bool { !all.isEmpty }

    func handle(_ action: HotkeyTap.Action) {
        if case .start(let mode, let reverse) = action { return start(mode, reverse: reverse) }
        if case .prepare = action {
            let t0 = CFAbsoluteTimeGetCurrent()
            WindowList.prefetch()
            return debugLog(String(format: "timing prepare %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
        guard isOpen else {
            // Nothing to show (e.g. no windows); make sure the hotkey doesn't stay engaged.
            onDismiss?()
            return
        }
        switch action {
        case .start, .prepare: break
        case .next: stepForward()
        case .previous: stepBack()
        case .jump(let n):
            if visible.indices.contains(n - 1) { finish(focusing: visible[n - 1]) }
        case .launch(let key):
            if let index = launcherKeys.firstIndex(of: key) {
                launch(index)
            } else if let letter = key.last, letter.isLetter {
                // No app has Shift+this letter: it's just typing (Shift+C filters by "c").
                type(String(letter))
            }
        case .togglePin:
            if focus == .list, let id = selectedID { togglePin(id) }
        case .stayOpen:
            enterStayOpen()
        case .type(let text):
            // A letter that's an app's own key opens it, unless you're already filtering: the
            // filter has text or focus, or keep-open mode is on.
            if query.isEmpty, focus != .filter, !stayOpen, let index = launcherKeys.firstIndex(of: text) {
                return launch(index)
            }
            type(text)
        case .deleteBackward:
            guard !query.isEmpty else { return }
            focus = .list
            query.removeLast()
            applyFilter(selectFirst: true)
            render()
        case .confirm, .commit:
            switch focus {
            case .list: finish(focusing: selectedIndex.map { visible[$0] })
            case .filter: finish(focusing: nil)
            case .launcher(let i): launch(i)
            }
        case .escape:
            if query.isEmpty {
                finish(focusing: nil)
            } else {
                query = ""
                applyFilter(selectFirst: false)
                render()
            }
        }
    }

    private func start(_ mode: SwitcherMode, reverse: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        self.mode = mode
        let screen = WindowList.onScreen()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let current: CGWindowID?
        switch mode {
        case .windows:
            all = WindowList.order(WindowList.build(screen, snapshots: tracker.snapshots), mru: tracker.mru)
            current = screen.first { $0.pid == frontPid }?.id
        case .apps:
            all = runningApps(screen: screen)
            current = frontPid.map { CGWindowID($0) }
        }
        guard !all.isEmpty else {
            onDismiss?()
            return
        }
        // Normally all[0] is the item you're in, so "previous" is all[1]. If the front app has
        // no listed window (e.g. Finder with none open), all[0] is already the previous one.
        let previous = all[0].id == current ? min(1, all.count - 1) : 0
        launchers = Settings.quickLaunchApps
        launcherKeys = QuickLaunch.keys(launchers)
        launcherItems = zip(launchers, launcherKeys).map { .init(name: $0.name, icon: $0.icon, shortcut: QuickLaunch.label($1)) }
        query = ""
        focus = .list
        applyFilter(selectFirst: false)
        // Pins are listed first, so pick the start window by MRU position, then find it.
        selectedID = reverse ? visible.last?.id : all[previous].id
        debugLog(String(format: "timing start %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        debugLog("start \(mode) current=\(current ?? 0) selected=\(selectedID ?? 0) list=" + visible.prefix(5).map { "\($0.appName)#\($0.id)" }.joined(separator: ", ") + " pinned=\(pinned)")
        // Cache misses (new apps/windows) show app name only; fill them in for next time.
        if mode == .windows {
            for pid in Set(all.filter { $0.element == nil }.map(\.pid)) { tracker.refresh(pid) }
        }
        let timer = Timer(timeInterval: showDelay, repeats: false) { [weak self] _ in self?.reveal() }
        RunLoop.main.add(timer, forMode: .common) // also fire while a menu is tracking
        showTimer = timer
        // Build the panel off-screen during the delay, after any already-queued keys (a quick
        // tap's release should switch without waiting on the build).
        DispatchQueue.main.async { [weak self] in
            guard let self, isOpen, showTimer != nil else { return }
            render(offscreen: true)
        }
    }

    /// Delay over: show the panel built during it (or build it now if that hasn't run yet).
    private func reveal() {
        showTimer = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        if !panel.reveal() { render() }
        debugLog(String(format: "timing reveal %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// Builds the panel once from the current windows, invisibly, and throws it away, so the
    /// first real opening doesn't pay for one-time setup (fonts, view classes, window-server
    /// windows): measured ~73 ms -> ~27 ms for that first build on 3 displays.
    func warmUp() {
        guard !isOpen else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let windows = WindowList.order(WindowList.build(WindowList.onScreen(), snapshots: tracker.snapshots), mru: tracker.mru)
        let rows = windows.enumerated().map { i, w in
            SwitcherPanel.Row(window: w, number: i < 10 ? String((i + 1) % 10) : nil, isPinned: false)
        }
        let apps = Settings.quickLaunchApps
        let launchers = zip(apps, QuickLaunch.keys(apps)).map {
            SwitcherPanel.Launcher(name: $0.name, icon: $0.icon, shortcut: QuickLaunch.label($1))
        }
        panel.show(rows, selected: rows.isEmpty ? nil : 0, query: "", stayOpen: false,
                   placeholder: "Type to filter windows", visible: false, launchers: launchers)
        panel.prime()
        panel.hide()
        debugLog(String(format: "timing warmUp %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// Regular apps (Dock apps) by most-recent activation, like the macOS Cmd+Tab list.
    private func runningApps(screen: [ScreenWindow]) -> [WindowInfo] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let apps = WindowList.runningApps.filter { $0.activationPolicy == .regular && $0.processIdentifier != myPid }
        let rank = Dictionary(tracker.appMRU.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let counts = Dictionary(grouping: screen, by: \.pid).mapValues(\.count)
        return apps.sorted { (rank[$0.processIdentifier] ?? .max) < (rank[$1.processIdentifier] ?? .max) }.map { app in
            let pid = app.processIdentifier
            let name = app.localizedName ?? "?"
            let count = counts[pid] ?? 0
            let subtitle = app.isHidden ? "hidden" : count == 0 ? name : count == 1 ? "1 window" : "\(count) windows"
            return WindowInfo(id: CGWindowID(pid), pid: pid, element: nil, title: name, appName: subtitle, icon: AppIcons.icon(for: app))
        }
    }

    /// Closes the switcher and opens the quick-launch app at `index` (0-based).
    private func launch(_ index: Int) {
        guard launchers.indices.contains(index) else { return }
        let app = launchers[index]
        finish(focusing: nil)
        QuickLaunch.open(app)
    }

    private var selectedIndex: Int? {
        selectedID.flatMap { id in visible.firstIndex { $0.id == id } }
    }

    /// Recomputes `visible` from `all`, the query and pins. Callers render.
    private func applyFilter(selectFirst: Bool) {
        let tokens = query.split(separator: " ").map { $0.lowercased() }
        let matches = all.filter { w in
            let haystack = "\(w.title) \(w.appName)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
        let pinnedRank = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        visible = matches.filter { pinnedRank[$0.id] != nil }.sorted { pinnedRank[$0.id]! < pinnedRank[$1.id]! }
            + matches.filter { pinnedRank[$0.id] == nil }
        if selectFirst || selectedIndex == nil { selectedID = visible.first?.id }
    }

    /// Adds typed text to the filter.
    private func type(_ text: String) {
        focus = .list
        query += text
        applyFilter(selectFirst: true)
        render()
    }

    /// Tab / → / ↓: down the list (wrapping at the end); from the quick-launch icons, right
    /// and then back down to the filter; from the filter, to the first row.
    private func stepForward() {
        switch focus {
        case .list:
            return move(+1)
        case .filter:
            focus = .list
            selectedID = visible.first?.id
        case .launcher(let i):
            focus = i + 1 < shownLaunchers ? .launcher(i + 1) : .filter
        }
        render()
    }

    /// Shift+Tab / ← / ↑: up the list; from the first row to the filter (rather than wrapping
    /// to the oldest window), then to the first quick-launch icon, then left along the icons.
    private func stepBack() {
        switch focus {
        case .list:
            if let index = selectedIndex, index > 0 { return move(-1) }
            focus = .filter
        case .filter:
            guard shownLaunchers > 0 else { return }
            focus = .launcher(0)
        case .launcher(let i):
            guard i > 0 else { return }
            focus = .launcher(i - 1)
        }
        render()
    }

    /// Quick-launch icons that fit in the bar (and so can take keyboard focus).
    private var shownLaunchers: Int { min(launcherItems.count, panel.shownLauncherCount) }

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let current = selectedIndex ?? 0
        selectedID = visible[(current + delta + visible.count) % visible.count].id
        render()
    }

    private func togglePin(_ id: CGWindowID) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) } else { pinned.append(id) }
        applyFilter(selectFirst: false)
        render()
    }

    /// Moves `id` into `target`'s slot in the pin order (by ID, so it works while filtered).
    private func movePin(_ id: CGWindowID, to target: CGWindowID) {
        guard let dest = pinned.firstIndex(of: target), let src = pinned.firstIndex(of: id) else { return }
        pinned.remove(at: src)
        pinned.insert(id, at: dest)
        applyFilter(selectFirst: false)
        render()
    }

    private func enterStayOpen() {
        guard isOpen, !stayOpen else { return }
        stayOpen = true
        onStayOpen?()
        // Clicks on our own panel are local events, so a global monitor only sees outside clicks.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.finish(focusing: nil)
        }
        render()
    }

    /// Rebuilds the panel. `offscreen` prepares it for `reveal()`; any other render (selection
    /// moved, typing) shows it immediately.
    private func render(offscreen: Bool = false) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { debugLog(String(format: "timing render %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
        if !offscreen {
            showTimer?.invalidate()
            showTimer = nil
        }
        let pinnedSet = Set(pinned)
        let rows = visible.enumerated().map { i, w in
            SwitcherPanel.Row(window: w, number: i < 10 ? String((i + 1) % 10) : nil, isPinned: pinnedSet.contains(w.id))
        }
        var focusedLauncher: Int?
        if case .launcher(let i) = focus { focusedLauncher = i }
        panel.show(rows, selected: focus == .list ? selectedIndex : nil, query: query, stayOpen: stayOpen,
                   placeholder: mode == .windows ? "Type to filter windows" : "Type to filter apps",
                   layout: mode == .apps ? Settings.appSwitcherLayout : .list, visible: !offscreen,
                   launchers: launcherItems, filterFocused: focus == .filter, focusedLauncher: focusedLauncher)
    }

    /// Single exit path: hides everything, resets per-session state, returns the hotkey to idle.
    private func finish(focusing target: WindowInfo?) {
        showTimer?.invalidate()
        showTimer = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel.hide()
        all = []
        visible = []
        selectedID = nil
        query = ""
        stayOpen = false
        onDismiss?()
        guard let target else { return }
        switch mode {
        case .windows:
            tracker.touch(target.id)
            WindowFocuser.focus(target)
        case .apps:
            tracker.touchApp(target.pid)
            // The app's most recent window on this Space, if any, becomes the key window.
            let windows = WindowList.order(WindowList.build(WindowList.onScreen(), snapshots: tracker.snapshots), mru: tracker.mru)
            let recent = windows.first { $0.pid == target.pid }
            if let recent { tracker.touch(recent.id) }
            WindowFocuser.activateApp(pid: target.pid, allWindows: Settings.appSwitchBringsAllWindows, window: recent)
        }
    }
}
