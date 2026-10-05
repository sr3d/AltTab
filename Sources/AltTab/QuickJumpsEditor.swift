import AppKit

/// Preferences list of Quick Jumps: drop folders and files (from Finder) or links (from a
/// browser) on it, or use + for a file chooser or a URL sheet; remove with − (or Delete), drag
/// to reorder, double-click a name to rename. Every change is saved immediately.
final class QuickJumpsEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let rowType = NSPasteboard.PasteboardType("com.sr3d.AltTab.quick-jump-row")

    private var jumps = Settings.quickJumps
    private let table = DeletableTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()

    /// The table plus its +/− buttons, `width` wide.
    func makeView(width: CGFloat) -> NSView {
        let column = NSTableColumn(identifier: .init("jump"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 36
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(renameClicked)
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.registerForDraggedTypes([Self.rowType, .fileURL, .URL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        addButton.target = self
        addButton.action = #selector(showAddMenu)
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")
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

    @objc private func showAddMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Add Folders or Files…", action: #selector(addFiles), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add URL…", action: #selector(addURL), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.maxY + 2), in: addButton)
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Add"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            insert(panel.urls.map { QuickJump(url: $0) }, at: jumps.count)
        }
        if let window = table.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// A sheet asking for the address and an optional name.
    @objc private func addURL() {
        let alert = NSAlert()
        alert.messageText = "Add a URL"
        alert.informativeText = "A web page (or any link) to open from the switcher."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let urlField = NSTextField(string: "")
        urlField.placeholderString = "https://example.com"
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Name (optional)"
        let fields = NSStackView(views: [urlField, nameField])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        for field in [urlField, nameField] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        alert.accessoryView = fields
        alert.window.initialFirstResponder = urlField
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let jump = QuickJump(typed: urlField.stringValue, name: nameField.stringValue) else {
                NSSound.beep()
                return
            }
            insert([jump], at: jumps.count)
        }
        if let window = table.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    @objc private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        jumps = jumps.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        save()
    }

    /// Adds bookmarks at `row`, skipping ones already in the list.
    private func insert(_ new: [QuickJump], at row: Int) {
        var seen = Set(jumps.map(\.url))
        let fresh = new.filter { seen.insert($0.url).inserted }
        guard !fresh.isEmpty else { return }
        jumps.insert(contentsOf: fresh, at: min(row, jumps.count))
        save()
    }

    @objc private func renameClicked() {
        let row = table.clickedRow
        guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? JumpCell else { return }
        table.window?.makeFirstResponder(cell.nameField)
    }

    /// A name edited in the list; empty goes back to the file's name or the URL's host.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard jumps.indices.contains(row) else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        jumps[row].customName = name.isEmpty || name == QuickJump(url: jumps[row].url).name ? nil : name
        save()
    }

    private func save() {
        Settings.quickJumps = jumps
        QuickJumps.warm()
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { jumps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let jump = jumps[row]
        let cell = JumpCell()
        let icon = NSImageView(image: jump.icon)
        let name = cell.nameField
        name.stringValue = jump.name
        name.isEditable = true
        name.isBordered = false
        name.drawsBackground = false
        name.focusRingType = .none
        name.lineBreakMode = .byTruncatingTail
        name.textColor = jump.exists ? .labelColor : .secondaryLabelColor
        name.delegate = self
        name.toolTip = "Double-click to rename"
        let detail = NSTextField(labelWithString: jump.exists ? jump.detail : "\(jump.detail) (not found)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        for v in [icon, name, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor, constant: 2),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 0),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Drag and drop (reorder rows; drop folders, files and links)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        if info.draggingSource as? NSTableView === tableView { return .move }
        return dropped(info).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === tableView {
            let moved = (info.draggingPasteboard.pasteboardItems ?? [])
                .compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }.sorted()
            guard !moved.isEmpty else { return false }
            let items = moved.map { jumps[$0] }
            let target = row - moved.filter { $0 < row }.count
            jumps = jumps.enumerated().filter { !moved.contains($0.offset) }.map(\.element)
            jumps.insert(contentsOf: items, at: target)
            save()
            return true
        }
        let new = dropped(info)
        insert(new, at: row)
        return !new.isEmpty
    }

    /// Files and folders from Finder, or links from a browser (named by the link's title when
    /// the browser provides one).
    private func dropped(_ info: NSDraggingInfo) -> [QuickJump] {
        let pasteboard = info.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let title = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name"))
        return urls.filter { $0.isFileURL || $0.scheme != nil }.map { url in
            QuickJump(url: url, name: url.isFileURL || urls.count > 1 ? nil : title)
        }
    }
}

/// A row in the list; keeps its name field so double-click can start editing it.
private final class JumpCell: NSTableCellView {
    let nameField = NSTextField()
}
