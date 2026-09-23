import AppKit

// File scope (not a static member) so the C calling convention has no hidden `self` argument.
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

/// Turns the macOS Cmd+Tab / Cmd+Shift+Tab switcher off while AltTab handles Cmd+Tab.
///
/// The Dock claims these shortcuts in the WindowServer before any event tap sees them, so they
/// must be disabled to be heard. The setting persists after our process exits, so it is
/// restored on quit, on termination signals, and on launch (in case a crash left it off).
/// Symbolic hotkey IDs 1 and 2 as used by alt-tab-macos (CGSSymbolicHotKey.swift).
enum NativeCommandTab {
    private static let hotkeys: [Int32] = [1, 2] // Cmd+Tab, Cmd+Shift+Tab
    private static var signalSources: [DispatchSourceSignal] = []

    static func setEnabled(_ enabled: Bool) {
        for id in hotkeys { CGSSetSymbolicHotKeyEnabled(id, enabled) }
    }

    /// Restores the native switcher if we get killed. Call once at launch.
    static func installRestoreHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN) // let the dispatch source receive it instead of the default handler
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                setEnabled(true)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        // Best effort on crashes: restore, then let the default handler produce the crash report.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            signal(sig) { sig in
                NativeCommandTab.setEnabled(true)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
}
