import AppKit
import CoreGraphics

/// Session event tap for Option+Tab and the keys used while the switcher is open.
/// While active, every key without Cmd is swallowed so nothing leaks into the front app.
/// The swallow decision is made inline, but actions are dispatched async so the
/// WindowServer never waits on our work (a slow tap stalls all input and gets disabled).
final class HotkeyTap {
    enum Action {
        case start(reverse: Bool), next, previous
        case jump(Int)                 // 1-based row number
        case togglePin, stayOpen, confirm, escape
        case type(String), deleteBackward
        case commit                    // Option released while held
    }

    enum Mode { case idle, held, stayOpen }

    var onAction: ((Action) -> Void)?
    private(set) var mode = Mode.idle
    private var tap: CFMachPort?

    private enum Key {
        static let tab: Int64 = 48, esc: Int64 = 53, backtick: Int64 = 50, equals: Int64 = 24
        static let backspace: Int64 = 51, returnKey: Int64 = 36, enter: Int64 = 76
    }
    // Left/up step back, right/down step forward, whichever way the list is laid out.
    private static let arrowKeys: [Int64: Action] = [123: .previous, 126: .previous, 124: .next, 125: .next]
    private static let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns to idle. The switcher calls this whenever it finishes (click, jump, Return, Esc…).
    func deactivate() {
        mode = .idle
    }

    /// Keeps the switcher open after Option is released (mouse use in the panel).
    func enterStayOpen() {
        if mode != .idle { mode = .stayOpen }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if mode == .held && !event.flags.contains(.maskAlternate) {
                mode = .idle
                send(.commit)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if mode == .idle {
                guard key == Key.tab && flags.contains(.maskAlternate)
                        && !flags.contains(.maskCommand) && !flags.contains(.maskControl) else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    mode = .held
                    send(.start(reverse: flags.contains(.maskShift)))
                }
                return nil
            }
            if flags.contains(.maskCommand) { return Unmanaged.passUnretained(event) }
            if type == .keyDown, let action = action(for: key, event) {
                if case .stayOpen = action { mode = .stayOpen }
                send(action)
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func action(for key: Int64, _ event: CGEvent) -> Action? {
        switch key {
        case Key.tab: return event.flags.contains(.maskShift) ? .previous : .next
        case Key.esc: return .escape
        case Key.backtick: return .stayOpen
        case Key.equals: return .togglePin
        case Key.backspace: return .deleteBackward
        case Key.returnKey, Key.enter: return .confirm
        default: break
        }
        if let arrow = Self.arrowKeys[key] { return arrow }
        if let digit = Self.digitKeys[key] { return .jump(digit) }
        // Read the character without modifiers so Option+T filters by "t", not "†".
        guard let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased(),
              let scalar = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil } // function/navigation keys
        return .type(chars)
    }

    private func send(_ action: Action) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
