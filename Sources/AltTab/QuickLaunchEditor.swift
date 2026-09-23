import AppKit
import UniformTypeIdentifiers

/// Preferences list of quick-launch apps: add with + (or drop apps from Finder), remove with −
/// (or Delete), drag to reorder, click an app's shortcut to give it its own key.
/// Every change is saved immediately.
final class QuickLaunchEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowType = NSPasteboard.PasteboardType("com.sr3d.AltTab.quick-launch-row")

    private var apps = Settings.quickLaunchApps
    private let table = DeletableTableView()
    private let removeButton = NSButton()

    /// The table plus its +/− buttons, `width` wide.
    func makeView(width: CGFloat) -> NSView {
        let column = NSTableColumn(identifier: .init("app"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 30
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.registerForDraggedTypes([Self.rowType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add app")!,
                                 target: self, action: #selector(addApps))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove app")
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        for button in [addButton, removeButton] {
            button.bezelStyle = .smallSquare
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = 0

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: 280),
        ])
        updateButtons()
        return stack
    }

    // MARK: Editing

    @objc private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            insert(panel.urls, at: apps.count)
        }
        if let window = table.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    @objc private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        apps = apps.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        save()
    }

    /// Adds app bundles at `row`, skipping non-apps and apps already in the list.
    private func insert(_ urls: [URL], at row: Int) {
        let new = urls.compactMap(QuickLaunchApp.init(url:)).filter { app in !apps.contains { $0.path == app.path } }
        guard !new.isEmpty else { return }
        apps.insert(contentsOf: new, at: min(row, apps.count))
        save()
    }

    /// Gives the app at `row` its own key token (nil: back to its position's digit). An app that
    /// already had that key loses it.
    private func setKey(_ key: String?, forRow row: Int) {
        guard apps.indices.contains(row) else { return }
        if let key {
            for i in apps.indices where apps[i].key == key { apps[i].key = nil }
        }
        apps[row].key = key
        save()
    }

    private func save() {
        Settings.quickLaunchApps = apps
        QuickLaunch.warm()
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = apps[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: app.icon)
        let name = NSTextField(labelWithString: app.location == nil ? "\(app.name) (not found)" : app.name)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = app.location == nil ? .secondaryLabelColor : .labelColor
        let shortcut = ShortcutRecorder(key: QuickLaunch.keys(apps)[row], isCustom: app.key != nil)
        shortcut.onChange = { [weak self] key in self?.setKey(key, forRow: row) }
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, name, shortcut] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = icon
        cell.textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Drag and drop (reorder rows; drop apps from Finder)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        if info.draggingSource as? NSTableView === tableView { return .move }
        return droppedApps(info).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === tableView {
            let moved = (info.draggingPasteboard.pasteboardItems ?? [])
                .compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }.sorted()
            guard !moved.isEmpty else { return false }
            let items = moved.map { apps[$0] }
            let target = row - moved.filter { $0 < row }.count
            apps = apps.enumerated().filter { !moved.contains($0.offset) }.map(\.element)
            apps.insert(contentsOf: items, at: target)
            save()
            return true
        }
        let urls = droppedApps(info)
        insert(urls, at: row)
        return !urls.isEmpty
    }

    private func droppedApps(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter { $0.pathExtension == "app" }
    }
}

/// An app's shortcut in the list ("C", "⇧C"). Click it, then press a letter (with or without
/// Shift) or Shift+digit to make that the app's key; Delete goes back to the position's digit;
/// Esc or clicking away cancels.
private final class ShortcutRecorder: NSButton {
    var onChange: ((String?) -> Void)?
    private let key: String?
    private let isCustom: Bool
    private var isRecording = false { didSet { updateTitle() } }

    init(key: String?, isCustom: Bool) {
        (self.key, self.isCustom) = (key, isCustom)
        super.init(frame: .zero)
        bezelStyle = .recessed
        showsBorderOnlyWhileMouseInside = true
        setButtonType(.momentaryPushIn)
        font = .monospacedDigitSystemFont(ofSize: 12, weight: isCustom ? .semibold : .regular)
        toolTip = "Click, then press a letter (C) or hold Shift for Shift+letter (⇧S) or Shift+digit to open this app with that key. Delete resets it."
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        let text = isRecording ? "Press a key…" : QuickLaunch.label(key) ?? "Set key"
        let color: NSColor = isRecording ? .controlAccentColor : isCustom ? .labelColor : .secondaryLabelColor
        attributedTitle = NSAttributedString(string: text, attributes: [.font: font as Any, .foregroundColor: color])
    }

    @objc private func startRecording() {
        isRecording = window?.makeFirstResponder(self) ?? false
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        // Without any modifiers: Shift+1 reads "1", not "!".
        let chars = event.characters(byApplyingModifiers: [])?.lowercased() ?? ""
        switch event.keyCode {
        case 53: // Esc
            window?.makeFirstResponder(nil)
        case 51, 117: // Delete, Forward Delete
            window?.makeFirstResponder(nil)
            onChange?(nil)
        default:
            let token = QuickLaunch.token(chars, shift: event.modifierFlags.contains(.shift))
            guard QuickLaunch.isValidKey(token) else { NSSound.beep(); return }
            window?.makeFirstResponder(nil)
            onChange?(token)
        }
    }
}

/// Table that removes the selection on Delete / Forward Delete.
private final class DeletableTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }
}
