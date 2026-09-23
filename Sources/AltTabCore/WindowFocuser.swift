import AppKit
import ApplicationServices

public enum WindowFocuser {
    /// Brings exactly one window to the front and makes it key, without pulling the
    /// app's other windows forward.
    public static func focus(_ window: WindowInfo) {
        if SkyLight.available {
            var psn = ProcessSerialNumber()
            GetProcessForPID(window.pid, &psn)
            _ = SkyLight.setFrontProcess?(&psn, window.id, SkyLight.userGenerated)
            SkyLight.makeKeyWindow(&psn, window.id)
            raise(window.element)
        } else {
            raise(window.element)
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        }
    }

    /// Activates an app. With `allWindows` every window comes forward like Cmd+Tab; otherwise only
    /// `window` (its most recent one) does. Apps with no windows are just made frontmost.
    public static func activateApp(pid: pid_t, allWindows: Bool, window: WindowInfo?) {
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.isHidden == true { app?.unhide() }
        if !allWindows, let window { return focus(window) }
        guard let setFront = SkyLight.setFrontProcess else {
            app?.activate(options: allWindows ? [.activateAllWindows] : [])
            return
        }
        var psn = ProcessSerialNumber()
        GetProcessForPID(pid, &psn)
        _ = setFront(&psn, 0, SkyLight.userGenerated | (allWindows ? SkyLight.allWindows : 0))
        if let window {
            SkyLight.makeKeyWindow(&psn, window.id)
            raise(window.element)
        }
    }

    /// Raises within the app's own window stack. AX IPC can block on a busy app, so it runs off
    /// the main thread; the SkyLight calls above already brought the window forward.
    private static func raise(_ element: AXUIElement?) {
        guard let element else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            AXUIElementSetMessagingTimeout(element, 1)
            raiseNow(element)
        }
    }

    private static func raiseNow(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
