import AltTabCore
import AppKit
import ApplicationServices
import os

/// Maintains, off the hot path:
/// - `mru`: window IDs by most-recent focus. Z-order alone is not MRU: a Cmd+Tab brings all
///   of an app's windows forward together.
/// - `snapshots`: cached AX windows per app. AX IPC can take seconds for a busy app, so it is
///   never done on keypress; it runs on a background queue and results land on main.
/// All stored state is main-thread only.
final class WindowTracker {
    private(set) var mru: [CGWindowID] = []
    private(set) var snapshots: [pid_t: AXSnapshot] = [:]

    private var observers: [pid_t: AXObserver] = [:]
    private var observing: Set<pid_t> = []
    private var inFlight: Set<pid_t> = []
    private var refreshTimer: Timer?
    private let axQueue = DispatchQueue(label: "AltTab.ax", qos: .userInitiated, attributes: .concurrent)
    private let maxEntries = 300
    private let myPid = ProcessInfo.processInfo.processIdentifier

    func start() {
        mru = WindowList.onScreen().map(\.id)
        let ws = NSWorkspace.shared
        for app in ws.runningApplications where app.activationPolicy == .regular {
            observe(app.processIdentifier)
        }
        refreshAll()

        let nc = ws.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let pid = Self.pid(note) else { return }
            observe(pid)
            recordFocusedWindow(of: pid)
            refresh(pid)
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(note) else { return }
            self?.observe(pid)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(note) else { return }
            self?.forget(pid)
        }
        // Titles and new windows in background apps; cheap because slow apps are never queued twice.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshAll() }
    }

    /// Moves a window to the front of the MRU list.
    func touch(_ id: CGWindowID) {
        debugLog("touch \(id)")
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > maxEntries { mru.removeLast(mru.count - maxEntries) }
    }

    func refreshAll() {
        for pid in Set(WindowList.onScreen().map(\.pid)) { refresh(pid) }
    }

    func refresh(_ pid: pid_t) {
        guard !inFlight.contains(pid) else { return }
        inFlight.insert(pid)
        axQueue.async { [weak self] in
            let snap = WindowList.snapshot(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(pid)
                if let snap { self.snapshots[pid] = snap }
            }
        }
    }

    fileprivate func recordFocusedWindow(of pid: pid_t) {
        // Background apps also change their focused window (e.g. while we raise one); only
        // the frontmost app's focus reflects what the user is looking at.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        axQueue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let id = windowID(of: value as! AXUIElement) else { return }
            DispatchQueue.main.async { self?.touch(id) }
        }
    }

    fileprivate func windowCreated(in pid: pid_t) {
        refresh(pid)
    }

    private func observe(_ pid: pid_t) {
        guard pid != myPid, !observing.contains(pid) else { return }
        observing.insert(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // AXObserverAddNotification is IPC and blocks on a hung app, so set up off main.
        axQueue.async { [weak self] in
            var observer: AXObserver?
            guard AXObserverCreate(pid, trackerCallback, &observer) == .success, let observer else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 2)
            for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
                AXObserverAddNotification(observer, app, n as CFString, refcon)
            }
            DispatchQueue.main.async {
                guard let self, self.observing.contains(pid) else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                self.observers[pid] = observer
            }
        }
    }

    private func forget(_ pid: pid_t) {
        observing.remove(pid)
        snapshots[pid] = nil
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private static func pid(_ note: Notification) -> pid_t? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }
}

private func trackerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    if CFEqual(notification, kAXWindowCreatedNotification as CFString) {
        tracker.windowCreated(in: pid)
    } else {
        tracker.recordFocusedWindow(of: pid)
    }
}

/// Enable with: defaults write com.sr3d.AltTab debug -bool true
/// View with:   log stream --predicate 'subsystem == "com.sr3d.AltTab"'
private let debugEnabled = UserDefaults.standard.bool(forKey: "debug")
private let logger = Logger(subsystem: "com.sr3d.AltTab", category: "debug")
func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    let text = message()
    logger.notice("\(text, privacy: .public)")
}
