import AltTabCore
import AppKit

/// How the switcher lays out its items: a vertical list, or (app switcher only) a horizontal
/// strip of big app icons like the macOS Cmd+Tab switcher.
enum SwitcherLayout: String { case list, icons }

/// Borderless, non-activating HUD listing windows; never takes focus from the target app.
/// Layout: a filter/hint header, then numbered rows (pinned first, separated by a hairline),
/// or a strip of numbered app icons with the selected app's name underneath. An optional
/// quick-launch bar of app icons (Shift+1…0) sits above the filter bar.
/// With "Show switcher on all displays" on, an identical copy is centered on every screen;
/// all copies share the callbacks below, so any of them can drive the switcher.
final class SwitcherPanel {
    struct Row {
        let window: WindowInfo
        let number: String?   // "1"…"9", "0"; nil past the tenth row
        let isPinned: Bool
    }

    /// A quick-launch bar item.
    struct Launcher {
        let name: String
        let icon: NSImage?
    }

    /// One HUD window and its row stack; SwitcherPanel keeps one per target screen.
    private final class ScreenPanel {
        let panel: NSPanel
        let stack = NSStackView()
        /// The rows (or icon tiles) built by the last `show`, restyled in place when only the
        /// selection changes.
        var rowViews: [RowView] = []
        /// Icons layout: the selected app's name under the strip.
        var nameLabel: NSTextField?
        /// List layout: shown beside the rows when they don't all fit.
        let scroller = ListScroller()

        init(onHover: @escaping (Int) -> Void, onScroll: @escaping (Int) -> Void, onScrollTo: @escaping (Int) -> Void) {
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
            scroller.isHidden = true
            scroller.onScrollTo = onScrollTo
            effect.addSubview(scroller)
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
    /// Click on a quick-launch icon (0-based).
    var onLaunch: ((Int) -> Void)?
    private var firstVisible = 0
    /// How many panels the last `show` filled in (one per target screen).
    private var shownCount = 0
    /// Everything the last `show` built from except the selection. When a call matches it, only
    /// the highlight moves (hover, arrows, Tab) instead of rebuilding every row on every screen.
    private struct Content: Equatable {
        var ids: [CGWindowID], titles: [String], names: [String], pins: [Bool], numbers: [String?]
        var query: String, stayOpen: Bool, placeholder: String, layout: SwitcherLayout
        var launchers: [String], screens: [NSRect], fontSize: CGFloat, firstVisible: Int
    }
    private var lastContent: Content?
    /// The selection the last `show` used; the list only follows the selection when it moves,
    /// so scrolling with the scrollbar isn't undone by the next highlight refresh.
    private var lastSelected: Int?
    /// The last `show` arguments, re-rendered when the scrollbar moves the list.
    private var lastShow: (() -> Void)?

    private func makeScreenPanel() -> ScreenPanel {
        ScreenPanel(onHover: { [weak self] in self?.onHover?($0) },
                    onScroll: { [weak self] in self?.onScroll?($0) },
                    onScrollTo: { [weak self] in self?.scroll(to: $0) })
    }

    /// Scrollbar: show the list from row `first` on, leaving the selection where it is.
    private func scroll(to first: Int) {
        guard first != firstVisible else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        firstVisible = first
        lastShow?()
        debugLog(String(format: "timing scroll to %d %.1fms", first, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// The screens to show on: every display, or just the one under the mouse.
    private var targetScreens: [NSScreen] {
        if Settings.showOnAllScreens, !NSScreen.screens.isEmpty { return NSScreen.screens }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return screen.map { [$0] } ?? []
    }

    func show(_ rows: [Row], selected: Int?, query: String, stayOpen: Bool, placeholder: String = "Type to filter",
              layout: SwitcherLayout = .list, visible: Bool = true, launchers: [Launcher] = []) {
        lastShow = { [weak self] in
            self?.show(rows, selected: selected, query: query, stayOpen: stayOpen, placeholder: placeholder,
                       layout: layout, visible: true, launchers: launchers)
        }
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
        // selection leaves it, so rows don't jump under the mouse; and only when the selection
        // (or the list) changed, so the scrollbar can show rows away from the selection.
        let count = min(rows.count, maxVisible)
        if count > 0 {
            let sel = selected ?? 0
            let changed = sel != lastSelected || rows.map(\.window.id) != lastContent?.ids
            if changed && !(firstVisible..<(firstVisible + count)).contains(sel) {
                firstVisible = sel - count / 2
            }
            firstVisible = max(0, min(firstVisible, rows.count - count))
        }
        lastSelected = selected
        let slice = firstVisible..<(firstVisible + count)
        let scrollable = layout == .list && rows.count > count

        let content = Content(ids: rows.map(\.window.id), titles: rows.map(\.window.title), names: rows.map(\.window.appName),
                              pins: rows.map(\.isPinned), numbers: rows.map(\.number), query: query, stayOpen: stayOpen,
                              placeholder: placeholder, layout: layout, launchers: launchers.map(\.name),
                              screens: screens.map(\.frame), fontSize: fontSize, firstVisible: firstVisible)
        if content == lastContent, shownCount == min(panels.count, screens.count) {
            for screenPanel in panels.prefix(shownCount) {
                screenPanel.rowViews.forEach { $0.setHighlighted($0.index == selected) }
                screenPanel.nameLabel?.attributedStringValue = selectedName(rows, selected)
                if visible && !screenPanel.panel.isVisible { screenPanel.panel.orderFrontRegardless() }
            }
            return
        }
        lastContent = content
        shownCount = min(panels.count, screens.count)

        for (screenPanel, screen) in zip(panels, screens) {
            let (panel, stack) = (screenPanel.panel, screenPanel.stack)
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            screenPanel.rowViews = []
            screenPanel.nameLabel = nil
            let area = screen.visibleFrame
            let width: CGFloat
            switch layout {
            case .list:
                width = min((600 * scale).rounded(), area.width - 40)
            case .icons:
                // Wide enough for the strip, and for the filter bar's hint text.
                let strip = CGFloat(count) * tile + (rows.contains(where: \.isPinned) ? 9 : 0)
                let bar = CGFloat(min(launchers.count, 10)) * (launcherCell + 4 * scale)
                width = min(max(strip + 16, bar + 16, (420 * scale).rounded()), area.width - 40)
            }
            let innerWidth = width - 16
            var height: CGFloat = 16
            screenPanel.scroller.isHidden = true

            if !launchers.isEmpty {
                let bar = makeLauncherBar(launchers, width: innerWidth)
                add(bar, to: stack, width: innerWidth)
                stack.setCustomSpacing(launcherGap, after: bar)
                height += launcherHeight + launcherGap
            }

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
                height += addIconStrip(rows, slice: slice, selected: selected, tile: tile, to: screenPanel, width: innerWidth)
            } else {
                // Rows leave a gutter on the right for the scrollbar when they don't all fit.
                let gutter = scrollable ? scrollerGutter : 0
                let rowsStart = height
                for i in slice {
                    if i > firstVisible && rows[i - 1].isPinned && !rows[i].isPinned {
                        let line = NSBox()
                        line.boxType = .separator
                        add(line, to: stack, width: innerWidth - gutter)
                        height += 1 + stack.spacing
                    }
                    let row = makeRow(rows[i], index: i, highlighted: i == selected)
                    screenPanel.rowViews.append(row)
                    add(row, to: stack, width: innerWidth - gutter)
                    height += rowHeight + stack.spacing
                }
                height -= stack.spacing
                if scrollable {
                    // The rows are the last thing in the panel: they end at the bottom inset.
                    let scroller = screenPanel.scroller
                    scroller.frame = NSRect(x: width - 8 - gutter, y: 8, width: gutter, height: height - rowsStart)
                    scroller.update(first: firstVisible, visible: count, total: rows.count, scale: scale)
                    scroller.isHidden = false
                }
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
                              to screenPanel: ScreenPanel, width: CGFloat) -> CGFloat {
        let stack = screenPanel.stack
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
            let tileView = makeTile(rows[i], index: i, highlighted: i == selected, size: tile)
            screenPanel.rowViews.append(tileView)
            strip.addArrangedSubview(tileView)
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

        let nameHeight = (26 * scale).rounded()
        let name = NSTextField(labelWithAttributedString: selectedName(rows, selected))
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.heightAnchor.constraint(equalToConstant: nameHeight).isActive = true
        screenPanel.nameLabel = name
        add(name, to: stack, width: width)
        return tile + stack.spacing + nameHeight
    }

    /// Icons layout: the selected app's name and its window count / "hidden", centered.
    private func selectedName(_ rows: [Row], _ selected: Int?) -> NSAttributedString {
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
        return text
    }

    /// One app in the icons layout: a big icon with the jump number in the top-left corner
    /// and the pin toggle in the top-right (shown when pinned or selected).
    private func makeTile(_ r: Row, index: Int, highlighted: Bool, size: CGFloat) -> RowView {
        let tile = RowView()
        tile.index = index
        tile.isPinned = r.isPinned
        tile.onMove = { [weak self] from, to in self?.onMovePin?(from, to) }
        tile.onMouseDown = { [weak self] in self?.onHighlight?(index) }
        tile.onClick = { [weak self] in self?.onChoose?(index) }
        tile.toolTip = r.window.title
        tile.wantsLayer = true
        tile.layer?.cornerRadius = size * 0.16

        let icon = NSImageView(image: r.window.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let badge = NSTextField(labelWithString: r.number ?? "")
        badge.font = .monospacedDigitSystemFont(ofSize: max(9, size * 0.11), weight: .semibold)
        badge.textColor = .secondaryLabelColor
        let pin = PinButton(pinned: r.isPinned, highlighted: false)
        pin.symbolConfiguration = .init(pointSize: max(9, size * 0.12), weight: .regular)
        pin.onClick = { [weak self] in self?.onTogglePin?(index) }
        tile.highlight = { [weak tile] on in
            tile?.layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            pin.isHidden = !(r.isPinned || on)
        }
        tile.setHighlighted(highlighted, force: true)

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

    /// Puts the built panels on screen fully transparent and takes them off again, so the window
    /// server sets their windows up now rather than on the first real opening.
    func prime() {
        for screenPanel in panels.prefix(shownCount) {
            screenPanel.panel.alphaValue = 0
            screenPanel.panel.orderFrontRegardless()
            screenPanel.panel.display()
        }
        for screenPanel in panels.prefix(shownCount) {
            screenPanel.panel.orderOut(nil)
            screenPanel.panel.alphaValue = 1
        }
    }

    func hide() {
        panels.forEach { $0.panel.orderOut(nil) }
        firstVisible = 0
        lastSelected = nil
        lastShow = nil
        shownCount = 0
        lastContent = nil
    }

    private func add(_ view: NSView, to stack: NSStackView, width: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private var scrollerGutter: CGFloat { (12 * scale).rounded() }

    // MARK: Quick-launch bar

    private var launcherCell: CGFloat { (44 * scale).rounded() }
    private var launcherHeight: CGFloat { (48 * scale).rounded() }
    private var launcherGap: CGFloat { (6 * scale).rounded() }

    /// App icons with their Shift+number shortcut underneath, left to right; as many as fit.
    private func makeLauncherBar(_ launchers: [Launcher], width: CGFloat) -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = (4 * scale).rounded()
        bar.heightAnchor.constraint(equalToConstant: launcherHeight).isActive = true
        let fit = max(1, Int((width + bar.spacing) / (launcherCell + bar.spacing)))
        for (i, launcher) in launchers.prefix(fit).enumerated() {
            let shortcut = QuickLaunch.shortcut(i)
            let button = LaunchButton()
            button.onClick = { [weak self] in self?.onLaunch?(i) }
            button.toolTip = shortcut.map { "\(launcher.name)  (\($0))" } ?? launcher.name
            button.wantsLayer = true
            button.layer?.cornerRadius = 7 * scale

            let icon = NSImageView(image: launcher.icon ?? NSImage())
            icon.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: shortcut ?? "")
            label.font = .systemFont(ofSize: 10 * scale, weight: .medium)
            label.textColor = .secondaryLabelColor
            for v in [icon, label] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(v)
            }
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: launcherCell),
                button.heightAnchor.constraint(equalToConstant: launcherHeight),
                icon.topAnchor.constraint(equalTo: button.topAnchor, constant: 3 * scale),
                icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: 30 * scale),
                icon.heightAnchor.constraint(equalToConstant: 30 * scale),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
                label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            ])
            bar.addArrangedSubview(button)
        }
        return bar
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

    private func makeRow(_ r: Row, index: Int, highlighted: Bool) -> RowView {
        let w = r.window
        let row = RowView()
        row.index = index
        row.isPinned = r.isPinned
        row.onMove = { [weak self] from, to in self?.onMovePin?(from, to) }
        row.onMouseDown = { [weak self] in self?.onHighlight?(index) }
        row.onClick = { [weak self] in self?.onChoose?(index) }
        row.wantsLayer = true
        row.layer?.cornerRadius = 8 * scale
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let badge = NSTextField(labelWithString: r.number ?? "")
        badge.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5 * scale
        badge.layer?.borderWidth = r.number == nil ? 0 : 1

        let icon = NSImageView(image: w.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown

        let text = w.title == w.appName ? w.appName : "\(w.title)  —  \(w.appName)"
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pin = PinButton(pinned: r.isPinned, highlighted: highlighted)
        pin.symbolConfiguration = .init(pointSize: fontSize, weight: .regular)
        pin.onClick = { [weak self] in self?.onTogglePin?(index) }

        let fontSize = fontSize
        row.highlight = { [weak row] on in
            row?.layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
            badge.textColor = on ? .white : .secondaryLabelColor
            badge.layer?.borderColor = (on ? NSColor.white.withAlphaComponent(0.6) : NSColor.tertiaryLabelColor).cgColor
            label.font = .systemFont(ofSize: fontSize, weight: on ? .semibold : .regular)
            label.textColor = on ? .white : .labelColor
            pin.style(highlighted: on)
        }
        row.setHighlighted(highlighted, force: true)

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
    /// Restyles the row's subviews for the selected / unselected look.
    var highlight: ((Bool) -> Void)?
    private var isHighlighted = false

    func setHighlighted(_ on: Bool, force: Bool = false) {
        guard force || on != isHighlighted else { return }
        isHighlighted = on
        highlight?(on)
    }

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

/// Scrollbar for the list layout. The list only builds the rows it shows, so this is a plain
/// view drawing a track and thumb for the visible slice; dragging the thumb (or clicking the
/// track) asks for the slice starting at the matching row.
final class ListScroller: NSView {
    var onScrollTo: ((Int) -> Void)?
    private var first = 0, visible = 1, total = 1
    private var scale: CGFloat = 1

    func update(first: Int, visible: Int, total: Int, scale: CGFloat) {
        (self.first, self.visible, self.total, self.scale) = (first, visible, max(total, 1), scale)
        needsDisplay = true
    }

    private var maxFirst: Int { max(total - visible, 0) }
    private var inset: CGFloat { 2 * scale }
    private var track: NSRect { bounds.insetBy(dx: 0, dy: inset) }
    private var thumbHeight: CGFloat {
        min(track.height, max(24 * scale, track.height * CGFloat(visible) / CGFloat(total)))
    }
    /// The thumb's distance below the top of the track.
    private func thumbOffset(for first: Int) -> CGFloat {
        maxFirst == 0 ? 0 : (track.height - thumbHeight) * CGFloat(first) / CGFloat(maxFirst)
    }
    private var thumb: NSRect {
        let barWidth = 6 * scale
        return NSRect(x: bounds.midX - barWidth / 2, y: track.maxY - thumbOffset(for: first) - thumbHeight,
                      width: barWidth, height: thumbHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth = 6 * scale
        let trackRect = NSRect(x: bounds.midX - barWidth / 2, y: track.minY, width: barWidth, height: track.height)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        NSColor.labelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, maxFirst > 0 else { return }
        // Where on the thumb it's held: the grab point on the thumb, or its middle when the
        // click lands on the track (which jumps the thumb there).
        let start = convert(event.locationInWindow, from: nil)
        let grab = thumb.contains(NSPoint(x: thumb.midX, y: start.y)) ? thumb.maxY - start.y : thumbHeight / 2
        func follow(_ e: NSEvent) {
            let y = convert(e.locationInWindow, from: nil).y
            let offset = track.maxY - y - grab
            let span = track.height - thumbHeight
            let row = span > 0 ? Int((offset / span * CGFloat(maxFirst)).rounded()) : 0
            onScrollTo?(max(0, min(row, maxFirst)))
        }
        follow(event)
        while let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp { return }
            follow(e)
        }
    }
}

/// The filter bar. Clicking it keeps the panel open so you can type.
private final class HeaderView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A quick-launch icon. Highlights on hover; a click opens the app.
private final class LaunchButton: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

/// Pin toggle inside a row. Handles its own clicks so they don't select/switch the row.
private final class PinButton: NSImageView {
    var onClick: (() -> Void)?
    private let pinned: Bool

    init(pinned: Bool, highlighted: Bool) {
        self.pinned = pinned
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "Unpin" : "Pin")
        imageScaling = .scaleProportionallyDown
        toolTip = pinned ? "Unpin (=)" : "Pin to top (=)"
        style(highlighted: highlighted)
    }

    func style(highlighted: Bool) {
        contentTintColor = pinned ? (highlighted ? .white : .systemOrange)
                                  : (highlighted ? NSColor.white.withAlphaComponent(0.5) : .quaternaryLabelColor)
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
