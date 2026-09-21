import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tap = HotkeyTap()
    private let tracker = WindowTracker()
    private lazy var switcher = Switcher(tracker: tracker)
    private var trustTimer: Timer?
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private lazy var preferences = PreferencesWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        accessibilityItem.target = self
        loginItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(loginItem)
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AltTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        tap.onAction = { [weak self] in self?.switcher.handle($0) }
        switcher.onDismiss = { [weak self] in self?.tap.deactivate() }
        switcher.onStayOpen = { [weak self] in self?.tap.enterStayOpen() }

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
        let ok = tap.install()
        if !ok { NSLog("AltTab: failed to create event tap") }
        updateStatus(trusted: ok)
    }

    private func updateStatus(trusted: Bool) {
        statusItem.button?.title = trusted ? "AltTab" : "AltTab ⚠︎"
        accessibilityItem.title = trusted ? "Accessibility: granted" : "Grant Accessibility Access…"
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showPreferences() {
        preferences.show()
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
        updateStatus(trusted: AXIsProcessTrusted())
    }
}
