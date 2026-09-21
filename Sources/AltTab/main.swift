import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Developer mode: render README screenshots and exit (see Screenshots.swift).
if let flag = CommandLine.arguments.firstIndex(of: "--screenshots") {
    let dir = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "docs"
    Screenshots.run(outputDirectory: dir)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
