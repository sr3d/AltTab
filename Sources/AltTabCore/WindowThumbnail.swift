import AppKit

/// Images of windows: small previews of other apps' windows (window groups), and our own
/// windows for screenshot rendering. Capturing another app's window needs Screen Recording
/// permission; without it macOS hands back only the wallpaper and frame, so `capture` returns
/// nil and callers show the app icon instead.
public enum WindowThumbnail {
    // CGWindowListCreateImage is unavailable in the macOS 15 SDK, so resolve it at runtime.
    // It still works for capturing our own windows without Screen Recording permission.
    private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: CreateImageFn.self)
    }()

    /// `CGWindowListCreateImage`. `rect` is in CG global coordinates (top-left of the primary screen).
    public static func image(rect: CGRect, options: CGWindowListOption, window: CGWindowID,
                             imageOptions: CGWindowImageOption) -> CGImage? {
        createImage?(rect, options.rawValue, window, imageOptions.rawValue)?.takeRetainedValue()
    }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static var askedForPermission = false

    /// Shows the system Screen Recording prompt, at most once per launch. Main thread only.
    public static func requestPermissionOnce() {
        guard !askedForPermission, !hasPermission else { return }
        askedForPermission = true
        CGRequestScreenCaptureAccess()
    }

    /// One window's contents (no frame or shadow), scaled down so its longer side is at most
    /// `maxPixels`. Nil without permission or when there's nothing to capture. Safe off the main thread.
    public static func capture(_ id: CGWindowID, maxPixels: CGFloat) -> NSImage? {
        guard hasPermission,
              let full = image(rect: .null, options: .optionIncludingWindow, window: id,
                               imageOptions: [.boundsIgnoreFraming, .nominalResolution]),
              full.width > 1, full.height > 1 else { return nil }
        let factor = min(1, maxPixels / CGFloat(max(full.width, full.height)))
        let width = max(1, Int(CGFloat(full.width) * factor)), height = max(1, Int(CGFloat(full.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
    }
}
