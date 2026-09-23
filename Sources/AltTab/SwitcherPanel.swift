import AltTabCore
import AppKit

/// How the switcher lays out its items: a vertical list, or (app switcher only) a horizontal
/// strip of big app icons like the macOS Cmd+Tab switcher.
enum SwitcherLayout: String { case list, icons }

/// Borderless, non-activating HUD listing windows; never takes focus from the target app.
/// Layout: a filter/hint header, then numbered rows (pinned first, separated by a hairline),
/// or a strip of numbered app icons with the selected app's name underneath.
/// With "Show switcher on all displays" on, an identical copy is centered on every screen;
/// all copies share the callbacks below, so any of them can drive the switcher.
final class SwitcherPanel {
    struct Row {
        let window: WindowInfo
        let number: String?   // "1"…"9", "0"; nil past the tenth row
        let isPinned: Bool
    }

    /// One HUD window and its row stack; SwitcherPanel keeps one per target screen.
    private final class ScreenPanel {
        let panel: NSPanel
        let stack = NSStackView()

        init(onHover: @escaping (Int) -> Void, onScroll: @escaping (Int) -> Void) {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false

            let effect = PanelContentView()
            effect.onHover = onHover
            effect.onScroll = onScroll
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true

            stack.orientation = .vertical
            stack.spacing = 2
            stack.alignment = .leading
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
            ])
            panel.contentView = effect
        }
    }

    private lazy var panels: [ScreenPanel] = [makeScreenPanel()]
    private let maxVisibleRows = 12
    // Everything is sized from the user's font size (Preferences); 14 pt is the 1x design.
    private var fontSize: CGFloat { Settings.fontSize }
    private var scale: CGFloat { fontSize / 14 }
    private var rowHeight: CGFloat { (40 * scale).rounded() }
    private var headerHeight: CGFloat { (32 * scale).rounded() }
    /// Mouse down on a row: highlight it. Mouse up on the same row: switch to it.
    var onHighlight: ((Int) -> Void)?
    var onChoose: ((Int) -> Void)?
    var onTogglePin: ((Int) -> Void)?
    /// Dragging a pinned row over another pinned row: move it to that row's position.
    var onMovePin: ((_ from: Int, _ to: Int) -> Void)?
    /// Click on the filter bar (keeps the panel open for typing).
    var onHeaderClick: (() -> Void)?
    /// Mouse moved over a row / scroll wheel steps (+1 down, -1 up).
    var onHover: ((Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    private var firstVisible = 0
    /// How many panels the last `show` filled in (one per target screen).
    private var shownCount = 0

    private func makeScreenPanel() -> ScreenPanel {
        ScreenPanel(onHover: { [weak self] in self?.onHover?($0) },
                    onScroll: { [weak self] in self?.onScroll?($0) })
    }

    /// The screens to show on: every display, or just the one under the mouse.
    private var targetScreens: [NSScreen] {
        if Settings.showOnAllScreens, !NSScreen.screens.isEmpty { return NSScreen.screens }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return screen.map { [$0] } ?? []
    }

    func show(_ rows: [Row], selected: Int?, query: String, stayOpen: Bool, placeholder: String = "Type to filter",
              layout: SwitcherLayout = .list, visible: Bool = true) {
        let screens = targetScreens
        // Match one panel per screen; handles displays added/removed between invocations.
        // Extra panels are dropped (not reused elsewhere) so each one keeps its own screen.
        while panels.count > max(screens.count, 1) { panels.removeLast().panel.orderOut(nil) }
        while panels.count < screens.count { panels.append(makeScreenPanel()) }

        // Icons shrink to fit the narrowest target screen, so every copy shows the same tiles.
        let narrowest = screens.map(\.visibleFrame.width).min() ?? 800
        let stripSpace = narrowest - 40 - 16 - 9 // panel margin, padding, pinned-group gap
        let tile = tileSize(count: rows.count, available: stripSpace)
        let maxVisible = layout == .list ? maxVisibleRows : max(1, Int(stripSpace / tile))

        // Show a slice of rows that keeps the selection in view. It only scrolls when the
        // selection leaves it, so rows don't jump under the mouse.
        let count = min(rows.count, maxVisible)
        if count > 0 {
            let sel = selected ?? 0
            if !(firstVisible..<(firstVisible + count)).contains(sel) || firstVisible + count > rows.count {
                firstVisible = max(0, min(sel - count / 2, rows.count - count))
            }
        }
        let slice = firstVisible..<(firstVisible + count)
        shownCount = min(panels.count, screens.count)

        for (screenPanel, screen) in zip(panels, screens) {
            let (panel, stack) = (screenPanel.panel, screenPanel.stack)
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let area = screen.visibleFrame
            let width: CGFloat
            switch layout {
            case .list:
                width = min((600 * scale).rounded(), area.width - 40)
            case .icons:
                // Wide enough for the strip, and for the filter bar's hint text.
                let strip = CGFloat(count) * tile + (rows.contains(where: \.isPinned) ? 9 : 0)
                width = min(max(strip + 16, (420 * scale).rounded()), area.width - 40)
            }
            let innerWidth = width - 16
            var height: CGFloat = 16

            let header = makeHeader(query: query, stayOpen: stayOpen, placeholder: placeholder)
            add(header, to: stack, width: innerWidth)
            height += headerHeight + stack.spacing

            if rows.isEmpty {
                let empty = NSTextField(labelWithString: "No matches")
                empty.textColor = .secondaryLabelColor
                empty.font = .systemFont(ofSize: fontSize)
                empty.alignment = .center
                empty.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                add(empty, to: stack, width: innerWidth)
                height += rowHeight
            } else if layout == .icons {
                height += addIconStrip(rows, slice: slice, selected: selected, tile: tile, to: stack, width: innerWidth)
            } else {
                for i in slice {
                    if i > firstVisible && rows[i - 1].isPinned && !rows[i].isPinned {
                        let line = NSBox()
                        line.boxType = .separator
                        add(line, to: stack, width: innerWidth)
                        height += 1 + stack.spacing
                    }
                    add(makeRow(rows[i], index: i, highlighted: i == selected), to: stack, width: innerWidth)
                    height += rowHeight + stack.spacing
                }
                height -= stack.spacing
            }

            // Keep the top edge fixed while the list shrinks/grows during filtering
            // (unless the panel is moving to a different screen).
            let staysOnScreen = panel.isVisible && screen.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 1))
            let top = staysOnScreen ? panel.frame.maxY : area.midY + height / 2
            panel.setFrame(NSRect(x: area.midX - width / 2, y: top - height, width: width, height: height), display: true)
            panel.invalidateShadow() // otherwise the shadow keeps the previous (square) shape
            if visible { panel.orderFrontRegardless() }

        }
    }

    // MARK: Icons layout

    /// Tile edge for the icons layout: full size when the apps fit, shrinking (like macOS) down
    /// to a minimum, past which the strip scrolls with the selection.
    private func tileSize(count: Int, available: CGFloat) -> CGFloat {
        let full = (104 * scale).rounded(), smallest = (56 * scale).rounded()
        guard count > 0 else { return full }
        return max(smallest, min(full, (available / CGFloat(count)).rounded(.down)))
    }

    /// Adds a centered horizontal strip of app tiles, then the selected app's name below it
    /// (like the macOS switcher). Returns the height added.
    private func addIconStrip(_ rows: [Row], slice: Range<Int>, selected: Int?, tile: CGFloat,
                              to stack: NSStackView, width: CGFloat) -> CGFloat {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 0
        for i in slice {
            if i > slice.lowerBound && rows[i - 1].isPinned && !rows[i].isPinned {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                let gap = NSView()
                gap.addSubview(line)
                NSLayoutConstraint.activate([
                    gap.widthAnchor.constraint(equalToConstant: 9),
                    gap.heightAnchor.constraint(equalToConstant: tile),
                    line.widthAnchor.constraint(equalToConstant: 1),
                    line.centerXAnchor.constraint(equalTo: gap.centerXAnchor),
                    line.topAnchor.constraint(equalTo: gap.topAnchor, constant: tile * 0.2),
                    line.bottomAnchor.constraint(equalTo: gap.bottomAnchor, constant: -tile * 0.2),
                ])
                strip.addArrangedSubview(gap)
            }
            strip.addArrangedSubview(makeTile(rows[i], index: i, highlighted: i == selected, size: tile))
        }
        let row = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(strip)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: tile),
            strip.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            strip.topAnchor.constraint(equalTo: row.topAnchor),
            strip.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        add(row, to: stack, width: width)

        // The selected app's name and its window count / "hidden".
        let nameHeight = (26 * scale).rounded()
        let text = NSMutableAttributedString()
        if let selected, rows.indices.contains(selected) {
            let w = rows[selected].window
            text.append(NSAttributedString(string: w.title, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.labelColor]))
            if w.appName != w.title {
                text.append(NSAttributedString(string: "  ·  \(w.appName)", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize * 0.85), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: text.length))
        let name = NSTextField(labelWithAttributedString: text)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.heightAnchor.constraint(equalToConstant: nameHeight).isActive = true
        add(name, to: stack, width: width)
        return tile + stack.spacing + nameHeight
    }

    /// One app in the icons layout: a big icon with the jump number in the top-left corner
    /// and the pin toggle in the top-right (shown when pinned or selected).
    private func makeTile(_ r: Row, index: Int, highlighted: Bool, size: CGFloat) -> NSView {
        let tile = RowView()
        tile.index = index
        tile.isPinned = r.isPinned
        tile.onMove = { [weak self] from, to in self?.onMovePin?(from, to) }
        tile.onMouseDown = { [weak self] in self?.onHighlight?(index) }
        tile.onClick = { [weak self] in self?.onChoose?(index) }
        tile.toolTip = r.window.title
        tile.wantsLayer = true
        tile.layer?.cornerRadius = size * 0.16
        tile.layer?.backgroundColor = highlighted ? NSColor.labelColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor

        let icon = NSImageView(image: r.window.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let badge = NSTextField(labelWithString: r.number ?? "")
        badge.font = .monospacedDigitSystemFont(ofSize: max(9, size * 0.11), weight: .semibold)
        badge.textColor = .secondaryLabelColor
        let pin = PinButton(pinned: r.isPinned, highlighted: false)
        pin.symbolConfiguration = .init(pointSize: max(9, size * 0.12), weight: .regular)
        pin.onClick = { [weak self] in self?.onTogglePin?(index) }
        pin.isHidden = !(r.isPinned || highlighted)

        for v in [icon, badge, pin] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(v)
        }
        let inset = size * 0.08
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: size * 0.78),
            icon.heightAnchor.constraint(equalToConstant: size * 0.78),
            badge.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: inset),
            badge.topAnchor.constraint(equalTo: tile.topAnchor, constant: inset * 0.6),
            pin.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -inset * 0.6),
            pin.topAnchor.constraint(equalTo: tile.topAnchor, constant: inset * 0.6),
            pin.widthAnchor.constraint(equalToConstant: size * 0.2),
            pin.heightAnchor.constraint(equalToConstant: size * 0.2),
        ])
        return tile
    }

    /// For screenshot rendering: the (first) panel's window number and frame (screen coordinates).
    var windowNumber: Int { panels[0].panel.windowNumber }
    var frame: NSRect { panels[0].panel.frame }

    /// Shows panels already built by `show(..., visible: false)`. False if there's nothing built.
    func reveal() -> Bool {
        guard shownCount > 0 else { return false }
        panels.prefix(shownCount).forEach { $0.panel.orderFrontRegardless() }
        return true
    }

    func hide() {
        panels.forEach { $0.panel.orderOut(nil) }
        firstVisible = 0
        shownCount = 0
    }

    private func add(_ view: NSView, to stack: NSStackView, width: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func makeHeader(query: String, stayOpen: Bool, placeholder: String) -> NSView {
        let header = HeaderView()
        header.onClick = { [weak self] in self?.onHeaderClick?() }
        header.heightAnchor.constraint(equalToConstant: headerHeight).isActive = true
        // A white text field so it reads as type-able in any theme; the accent ring and caret
        // show it's focused (stay-open mode, where typing goes to the filter).
        header.wantsLayer = true
        header.layer?.cornerRadius = 7 * scale
        header.layer?.backgroundColor = NSColor.white.cgColor
        header.layer?.borderWidth = stayOpen ? 2 : 1
        header.layer?.borderColor = (stayOpen ? NSColor.controlAccentColor : NSColor(white: 0.75, alpha: 1)).cgColor
        header.toolTip = stayOpen ? nil : "Click to keep open and type"

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.contentTintColor = NSColor(white: 0.45, alpha: 1)
        glass.symbolConfiguration = .init(pointSize: fontSize, weight: .regular)
        let font = NSFont.systemFont(ofSize: fontSize, weight: query.isEmpty ? .regular : .medium)
        let text = NSMutableAttributedString(string: query, attributes: [.font: font, .foregroundColor: NSColor.black])
        if stayOpen {
            text.append(NSAttributedString(string: "▏", attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor]))
        }
        if query.isEmpty {
            text.append(NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(white: 0.55, alpha: 1)]))
        }
        let field = NSTextField(labelWithAttributedString: text)
        field.lineBreakMode = .byTruncatingHead
        let hint = NSTextField(labelWithString: stayOpen ? "↩ switch · esc close · = pin" : "` keep open · = pin · 1–0 jump")
        hint.font = .systemFont(ofSize: 11 * scale)
        hint.textColor = NSColor(white: 0.55, alpha: 1)
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [glass, field, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10 * scale),
            glass.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16 * scale),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8 * scale),
            field.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
            hint.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func makeRow(_ r: Row, index: Int, highlighted: Bool) -> NSView {
        let w = r.window
        let row = RowView()
        row.index = index
        row.isPinned = r.isPinned
        row.onMove = { [weak self] from, to in self?.onMovePin?(from, to) }
        row.onMouseDown = { [weak self] in self?.onHighlight?(index) }
        row.onClick = { [weak self] in self?.onChoose?(index) }
        row.wantsLayer = true
        row.layer?.cornerRadius = 8 * scale
        row.layer?.backgroundColor = highlighted ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let badge = NSTextField(labelWithString: r.number ?? "")
        badge.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        badge.alignment = .center
        badge.textColor = highlighted ? .white : .secondaryLabelColor
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5 * scale
        badge.layer?.borderWidth = r.number == nil ? 0 : 1
        badge.layer?.borderColor = (highlighted ? NSColor.white.withAlphaComponent(0.6) : NSColor.tertiaryLabelColor).cgColor

        let icon = NSImageView(image: w.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown

        let text = w.title == w.appName ? w.appName : "\(w.title)  —  \(w.appName)"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: fontSize, weight: highlighted ? .semibold : .regular)
        label.textColor = highlighted ? .white : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pin = PinButton(pinned: r.isPinned, highlighted: highlighted)
        pin.symbolConfiguration = .init(pointSize: fontSize, weight: .regular)
        pin.onClick = { [weak self] in self?.onTogglePin?(index) }

        for v in [badge, icon, label, pin] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20 * scale),
            icon.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28 * scale),
            icon.heightAnchor.constraint(equalToConstant: 28 * scale),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -8),
            pin.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            pin.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 28 * scale),
            pin.heightAnchor.constraint(equalToConstant: 28 * scale),
        ])
        return row
    }
}

/// A clickable row. The panel never becomes key or active, so accept the first click.
/// Pinned rows can also be dragged onto other pinned rows to reorder them.
private final class RowView: NSView {
    var index = 0
    var isPinned = false
    var onMouseDown: (() -> Void)?
    var onClick: (() -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Rows are rebuilt on every selection change (and on every reorder step), so the view
    // that got mouseDown may be gone by mouseUp. Run the whole gesture here, hit-testing
    // the current rows, instead of relying on later events reaching this view.
    override func mouseDown(with event: NSEvent) {
        let (onClick, onMove, index, isPinned) = (onClick, onMove, index, isPinned)
        guard let window, let content = window.contentView else { return }
        onMouseDown?()
        func rowUnder(_ e: NSEvent) -> RowView? {
            let point = content.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow
            return content.hitTest(point)?.nearestRow
        }
        let start = event.locationInWindow
        var current = index
        var dragging = false
        while let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp {
                if dragging { NSCursor.pop() } else if rowUnder(e)?.index == index { onClick?() }
                return
            }
            guard isPinned else { continue }
            if !dragging {
                guard hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 4 else { continue }
                dragging = true
                NSCursor.closedHand.push()
            }
            if let target = rowUnder(e), target.isPinned, target.index != current {
                onMove?(current, target.index)
                current = target.index
            }
        }
    }
}

/// Root view: hover selects the row under the mouse, the scroll wheel steps the selection.
private final class PanelContentView: NSVisualEffectView {
    var onHover: ((Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    private var scrollAccumulator: CGFloat = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // mouseMoved (not mouseEntered) so a panel appearing under a still cursor selects nothing.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        if let row = hitTest(point)?.nearestRow { onHover?(row.index) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report many small precise deltas; mouse wheels report whole notches.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 20 : 1
        scrollAccumulator += event.scrollingDeltaY
        while scrollAccumulator >= step { scrollAccumulator -= step; onScroll?(-1) }
        while scrollAccumulator <= -step { scrollAccumulator += step; onScroll?(+1) }
    }
}

/// The filter bar. Clicking it keeps the panel open so you can type.
private final class HeaderView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Pin toggle inside a row. Handles its own clicks so they don't select/switch the row.
private final class PinButton: NSImageView {
    var onClick: (() -> Void)?

    init(pinned: Bool, highlighted: Bool) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "Unpin" : "Pin")
        imageScaling = .scaleProportionallyDown
        contentTintColor = pinned ? (highlighted ? .white : .systemOrange)
                                  : (highlighted ? NSColor.white.withAlphaComponent(0.5) : .quaternaryLabelColor)
        toolTip = pinned ? "Unpin (=)" : "Pin to top (=)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private extension NSView {
    var nearestRow: RowView? {
        var view: NSView? = self
        while let v = view { if let row = v as? RowView { return row }; view = v.superview }
        return nil
    }
}
