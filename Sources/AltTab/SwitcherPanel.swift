import AltTabCore
import AppKit

/// Borderless, non-activating HUD listing windows; never takes focus from the target app.
/// Layout: a filter/hint header, then numbered rows (pinned first, separated by a hairline).
final class SwitcherPanel {
    struct Row {
        let window: WindowInfo
        let number: String?   // "1"…"9", "0"; nil past the tenth row
        let isPinned: Bool
    }

    private let panel: NSPanel
    private let stack = NSStackView()
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

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let effect = PanelContentView()
        effect.onHover = { [weak self] in self?.onHover?($0) }
        effect.onScroll = { [weak self] in self?.onScroll?($0) }
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

    func show(_ rows: [Row], selected: Int?, query: String, stayOpen: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let width = min((600 * scale).rounded(), area.width - 40)
        let innerWidth = width - 16
        var height: CGFloat = 16

        let header = makeHeader(query: query, stayOpen: stayOpen)
        add(header, width: innerWidth)
        height += headerHeight + stack.spacing

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No matching windows")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: fontSize)
            empty.alignment = .center
            empty.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            add(empty, width: innerWidth)
            height += rowHeight
        } else {
            // Show a slice of rows that keeps the selection in view. It only scrolls when the
            // selection leaves it, so rows don't jump under the mouse.
            let count = min(rows.count, maxVisibleRows)
            let sel = selected ?? 0
            if !(firstVisible..<(firstVisible + count)).contains(sel) || firstVisible + count > rows.count {
                firstVisible = max(0, min(sel - count / 2, rows.count - count))
            }
            for i in firstVisible..<(firstVisible + count) {
                if i > firstVisible && rows[i - 1].isPinned && !rows[i].isPinned {
                    let line = NSBox()
                    line.boxType = .separator
                    add(line, width: innerWidth)
                    height += 1 + stack.spacing
                }
                add(makeRow(rows[i], index: i, highlighted: i == selected), width: innerWidth)
                height += rowHeight + stack.spacing
            }
            height -= stack.spacing
        }

        // Keep the top edge fixed while the list shrinks/grows during filtering.
        let top = panel.isVisible ? panel.frame.maxY : area.midY + height / 2
        panel.setFrame(NSRect(x: area.midX - width / 2, y: top - height, width: width, height: height), display: true)
        panel.invalidateShadow() // otherwise the shadow keeps the previous (square) shape
        panel.orderFrontRegardless()
    }

    /// For screenshot rendering: the panel's window number and frame (screen coordinates).
    var windowNumber: Int { panel.windowNumber }
    var frame: NSRect { panel.frame }

    func hide() {
        panel.orderOut(nil)
        firstVisible = 0
    }

    private func add(_ view: NSView, width: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func makeHeader(query: String, stayOpen: Bool) -> NSView {
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
            text.append(NSAttributedString(string: "Type to filter", attributes: [.font: font, .foregroundColor: NSColor(white: 0.55, alpha: 1)]))
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
