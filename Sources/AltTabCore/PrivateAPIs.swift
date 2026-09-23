import ApplicationServices
import Foundation

// Private-but-stable APIs used by alt-tab-macos, Hammerspoon and yabai.

/// Returns the CGWindowID backing an AX window element.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Deprecated/removed from headers, still exported. Returns the PSN for a pid.
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

public func windowID(of element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(element, &wid) == .success && wid != 0 ? wid : nil
}

/// SkyLight symbols, resolved at runtime so a missing symbol degrades to the public fallback.
enum SkyLight {
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    /// kCPSUserGenerated: front the process + only the given window, as a user-initiated switch.
    static let userGenerated: UInt32 = 0x200
    /// kCPSAllWindows: bring every window of the process forward (what Cmd+Tab does).
    static let allWindows: UInt32 = 0x100

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static let setFrontProcess: SetFrontProcessFn? = {
        guard let handle, let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(sym, to: SetFrontProcessFn.self)
    }()

    static let postEventRecord: PostEventRecordFn? = {
        guard let handle, let sym = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: PostEventRecordFn.self)
    }()

    static var available: Bool { setFrontProcess != nil && postEventRecord != nil }

    /// Makes `wid` the key window of its app by posting a synthetic left-mouse-down record to the
    /// WindowServer. Byte layout from alt-tab-macos (SkyLight.framework.swift, `makeKeyWindow`):
    /// 0x100 zeroed buffer; 0x04 record length 0xf8; 0x08 event type 1 (mouse down only);
    /// 0x20 window-relative CGPoint aimed far off-window; 0x3a flag 0x10; 0x3c target window id.
    static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        guard let postEventRecord else { return }
        var wid = wid
        var point = CGPoint(x: 300_000, y: 300_000)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: &wid) { src in for i in 0..<src.count { bytes[0x3c + i] = src[i] } }
        withUnsafeBytes(of: &point) { src in for i in 0..<src.count { bytes[0x20 + i] = src[i] } }
        _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
    }
}
