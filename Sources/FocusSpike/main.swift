// Step-0 spike: verify a single window can be raised without its siblings.
// Usage: swift run FocusSpike            -> list windows (front-to-back)
//        swift run FocusSpike <substr>   -> focus the first window whose title contains <substr>
import AltTabCore
import ApplicationServices
import Foundation

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
guard trusted else {
    print("Accessibility not granted for this terminal. Enable it in System Settings > Privacy & Security > Accessibility, then rerun.")
    exit(1)
}

let windows = WindowList.current()
guard CommandLine.arguments.count > 1 else {
    for (i, w) in windows.enumerated() { print("\(i)\t#\(w.id)\t\(w.appName)\t\(w.title)") }
    exit(0)
}

let needle = CommandLine.arguments[1].lowercased()
guard let target = windows.first(where: { $0.title.lowercased().contains(needle) }) else {
    print("No window matching '\(needle)'")
    exit(1)
}
print("Focusing #\(target.id) \(target.appName) — \(target.title)")
WindowFocuser.focus(target)
RunLoop.main.run(until: Date().addingTimeInterval(0.5)) // let the async AX raise finish
