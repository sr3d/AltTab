import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Developer mode: render README screenshots and exit (see Screenshots.swift).
if let flag = CommandLine.arguments.firstIndex(of: "--screenshots") {
    let dir = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "docs"
    Screenshots.run(outputDirectory: dir)
    exit(0)
}

// An accessory app shows no menu bar, but text fields still get ⌘X/C/V/A/Z only through a
// main menu's Edit items.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
edit.addItem(.separator())
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = edit
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
