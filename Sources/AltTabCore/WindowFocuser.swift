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
