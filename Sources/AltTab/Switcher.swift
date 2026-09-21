import AltTabCore
import AppKit

/// Ties the hotkey to the window list, panel and focuser.
/// Quick tap focuses the previous window; holding Option shows the panel after a short delay.
/// While open: pins sit at the top, rows are numbered 1-9, 0 for direct jumps, typing filters.
final class Switcher {
    private let tracker: WindowTracker
    private let panel = SwitcherPanel()
    private var all: [WindowInfo] = []        // MRU order for this session
    private var visible: [WindowInfo] = []    // pinned first, then the rest, filtered
    private var selectedID: CGWindowID?       // by ID so pinning/filtering keeps the selection
    private var query = ""
    private var stayOpen = false
    private var pinned: [CGWindowID] = []     // session-lifetime, in pin order
    private var showTimer: Timer?
    private var outsideClickMonitor: Any?
    private let showDelay: TimeInterval = 0.15
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
            guard let self, visible.indices.contains(index), visible[index].id != selectedID else { return }
            selectedID = visible[index].id
            render()
        }
        panel.onScroll = { [weak self] in self?.move($0) }
        panel.onMovePin = { [weak self] from, to in
            guard let self, visible.indices.contains(from), visible.indices.contains(to) else { return }
            movePin(visible[from].id, to: visible[to].id)
        }
    }

    private var isOpen: Bool { !all.isEmpty }

    func handle(_ action: HotkeyTap.Action) {
        if case .start(let reverse) = action { return start(reverse: reverse) }
        guard isOpen else {
            // Nothing to show (e.g. no windows); make sure the hotkey doesn't stay engaged.
            onDismiss?()
            return
        }
        switch action {
        case .start: break
        case .next: move(+1)
        case .previous: move(-1)
        case .jump(let n):
            if visible.indices.contains(n - 1) { finish(focusing: visible[n - 1]) }
        case .togglePin:
            if let id = selectedID { togglePin(id) }
        case .stayOpen:
            enterStayOpen()
        case .type(let text):
            query += text
            applyFilter(selectFirst: true)
            render()
        case .deleteBackward:
            guard !query.isEmpty else { return }
            query.removeLast()
            applyFilter(selectFirst: true)
            render()
        case .confirm, .commit:
            finish(focusing: selectedIndex.map { visible[$0] })
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

    private func start(reverse: Bool) {
        let screen = WindowList.onScreen()
        all = WindowList.order(WindowList.build(screen, snapshots: tracker.snapshots), mru: tracker.mru)
        guard !all.isEmpty else {
            onDismiss?()
            return
        }
        // Normally all[0] is the window you're in, so "previous" is all[1]. If the front app
        // has no listed window (e.g. Finder with none open), all[0] is already the previous one.
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let current = screen.first { $0.pid == frontPid }?.id
        let previous = all[0].id == current ? min(1, all.count - 1) : 0
        query = ""
        applyFilter(selectFirst: false)
        // Pins are listed first, so pick the start window by MRU position, then find it.
        selectedID = reverse ? visible.last?.id : all[previous].id
        debugLog("start current=\(current ?? 0) selected=\(selectedID ?? 0) list=" + visible.prefix(5).map { "\($0.appName)#\($0.id)" }.joined(separator: ", ") + " pinned=\(pinned)")
        // Cache misses (new apps/windows) show app name only; fill them in for next time.
        for pid in Set(all.filter { $0.element == nil }.map(\.pid)) { tracker.refresh(pid) }
        let timer = Timer(timeInterval: showDelay, repeats: false) { [weak self] _ in self?.render() }
        RunLoop.main.add(timer, forMode: .common) // also fire while a menu is tracking
        showTimer = timer
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

    private func render() {
        showTimer?.invalidate()
        showTimer = nil
        let pinnedSet = Set(pinned)
        let rows = visible.enumerated().map { i, w in
            SwitcherPanel.Row(window: w, number: i < 10 ? String((i + 1) % 10) : nil, isPinned: pinnedSet.contains(w.id))
        }
        panel.show(rows, selected: selectedIndex, query: query, stayOpen: stayOpen)
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
        if let target {
            tracker.touch(target.id)
            WindowFocuser.focus(target)
        }
    }
}
