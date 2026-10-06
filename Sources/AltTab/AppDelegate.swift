import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tap = HotkeyTap()
    private let tracker = WindowTracker()
    private lazy var switcher = Switcher(tracker: tracker)
    private var trustTimer: Timer?
    private var secureInputTimer: Timer?
    private var trusted = false
    /// PID holding Secure Keyboard Entry; while set, our event tap sees no keystrokes.
    private var secureInputPID: pid_t?
    private let secureInputItem = NSMenuItem(title: "", action: #selector(showSecureInputHolder), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private lazy var preferences = PreferencesWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        accessibilityItem.target = self
        loginItem.target = self
        secureInputItem.target = self
        secureInputItem.isHidden = true
        // Which build is running; no action, so it shows greyed out.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        menu.addItem(NSMenuItem(title: version.map { "AltTab \($0)" } ?? "AltTab (development build)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(secureInputItem)
        menu.addItem(accessibilityItem)
        menu.addItem(loginItem)
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let aboutItem = NSMenuItem(title: "About AltTab", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AltTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        refreshSecureInput()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshSecureInput()
        }
        secureInputTimer?.tolerance = 1

        // Restore the macOS Cmd+Tab if a previous run was killed while it was taken over;
        // it's re-disabled in activate() once the event tap is running.
        NativeCommandTab.setEnabled(true)
        NativeCommandTab.installRestoreHandlers()
        preferences.onChange = { [weak self] in self?.applyCommandTabSetting() }

        tap.onAction = { [weak self] in self?.switcher.handle($0) }
        switcher.onDismiss = { [weak self] in self?.tap.deactivate() }
        switcher.onStayOpen = { [weak self] in self?.tap.enterStayOpen() }
        switcher.onEditJumps = { [weak self] in self?.preferences.show(.quickJumps) }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            activate()
        } else {
            updateStatus(trusted: false)
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.activate()
            }
        }
    }

    private func activate() {
        tracker.start()
        // After the app icon cache warms (queued by tracker.start), so the warm-up uses it.
        DispatchQueue.main.async { [weak self] in
            QuickLaunch.warm()
            QuickJumps.warm()
            self?.switcher.warmUp()
        }
        // New displays get new panels; set those up too.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.switcher.warmUp()
        }
        let ok = tap.install()
        if !ok { NSLog("AltTab: failed to create event tap") }
        updateStatus(trusted: ok)
        applyCommandTabSetting()
    }

    /// Hands Cmd+Tab to AltTab (or back to macOS). Only takes it when our tap is running,
    /// so Cmd+Tab never ends up handled by nobody. Option+Tab gets whichever list Cmd+Tab
    /// doesn't show, so both stay a key away.
    private func applyCommandTabSetting() {
        let takeover = Settings.commandTabTakeover && tap.isInstalled
        tap.commandTabMode = takeover ? Settings.commandTabMode : nil
        tap.optionTabMode = takeover && Settings.commandTabMode == .windows ? .apps : .windows
        NativeCommandTab.setEnabled(!takeover)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeCommandTab.setEnabled(true)
    }

    private func updateStatus(trusted: Bool) {
        self.trusted = trusted
        accessibilityItem.title = trusted ? "Accessibility: granted" : "Grant Accessibility Access…"
        updateStatusTitle()
    }

    /// Secure Input wins over the ⚠︎: it's what is blocking the shortcuts right now.
    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        if let pid = secureInputPID {
            let title = NSMutableAttributedString(string: "AltTab ")
            title.append(NSAttributedString(string: "✕", attributes: [.foregroundColor: NSColor.systemRed]))
            button.attributedTitle = title
            button.toolTip = "Secure Input is on (\(Self.processName(pid))) — AltTab can't see keystrokes"
        } else {
            button.title = trusted ? "AltTab" : "AltTab ⚠︎"
            button.toolTip = nil
        }
    }

    /// PID of the process holding Secure Keyboard Entry, which blinds our event tap; nil if none.
    private static func secureInputHolder() -> pid_t? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = dict["kCGSSessionSecureInputPID"] as? Int, pid > 0 else { return nil }
        return pid_t(pid)
    }

    private static func processName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    private func refreshSecureInput() {
        let pid = Self.secureInputHolder()
        guard pid != secureInputPID else { return }
        secureInputPID = pid
        if let pid {
            secureInputItem.title = "Secure Input on (\(Self.processName(pid))) — shortcuts blocked"
        }
        secureInputItem.isHidden = pid == nil
        updateStatusTitle()
    }

    /// Brings the holder forward so the user can leave its password field or quit it.
    @objc private func showSecureInputHolder() {
        guard let pid = secureInputPID else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showPreferences() {
        preferences.show(.general)
    }

    @objc private func showAbout() {
        preferences.show(.about)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("AltTab: launch at login failed: \(error)")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshSecureInput()
        updateStatus(trusted: AXIsProcessTrusted())
    }
}
