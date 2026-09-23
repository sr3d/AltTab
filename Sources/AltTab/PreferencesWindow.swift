import AppKit
import ServiceManagement

/// Preferences: a General tab (font size, Cmd+Tab takeover, all displays, launch at login) and an About tab.
/// Changes are saved immediately; `onChange` lets the app apply them (e.g. the Cmd+Tab hotkey).
final class PreferencesWindow: NSWindowController {
    enum Tab: Int { case general, about }

    static let repoURL = URL(string: "https://github.com/sr3d/AltTab")!

    var onChange: (() -> Void)?

    private let tabs = NSTabViewController()
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "Sample window title  —  Sublime Text")
    private let takeoverBox = NSButton(checkboxWithTitle: "Use AltTab for Cmd+Tab", target: nil, action: nil)
    private let cmdWindowsRadio = NSButton(radioButtonWithTitle: "Windows (same as Option+Tab)", target: nil, action: nil)
    private let cmdAppsRadio = NSButton(radioButtonWithTitle: "Apps (like the macOS switcher)", target: nil, action: nil)
    private let layoutLabel = NSTextField(labelWithString: "App list layout:")
    private let layoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let showsLabel = NSTextField(labelWithString: "Cmd+Tab shows:")
    private let bringLabel = NSTextField(labelWithString: "When switching to an app, bring forward:")
    private let allWindowsRadio = NSButton(radioButtonWithTitle: "All of the app's windows (like macOS)", target: nil, action: nil)
    private let recentWindowRadio = NSButton(radioButtonWithTitle: "Only its most recent window", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let allScreensBox = NSButton(checkboxWithTitle: "Show switcher on all displays", target: nil, action: nil)
    private let contentWidth: CGFloat = 440

    init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // Toolbar-style tabs, like system Settings panes; the window resizes to each tab.
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item("General", symbol: "gearshape", generalView()))
        tabs.addTabViewItem(item("About", symbol: "info.circle", aboutView()))
        window.contentViewController = tabs
        window.title = "AltTab Preferences"
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab = .general) {
        sync()
        tabs.selectedTabViewItemIndex = tab.rawValue
        window?.center()
        // We're a menu-bar (accessory) app, so bring ourselves forward for the window to get focus.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: General

    private func generalView() -> NSView {
        let fontTitle = sectionTitle("Font size")
        slider.minValue = Settings.fontSizeRange.lowerBound
        slider.maxValue = Settings.fontSizeRange.upperBound
        slider.numberOfTickMarks = Int(Settings.fontSizeRange.upperBound - Settings.fontSizeRange.lowerBound) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.target = self
        slider.action = #selector(fontSizeChanged)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetFontSize))
        let fontRow = NSStackView(views: [slider, valueLabel, reset])
        fontRow.spacing = 8
        preview.lineBreakMode = .byTruncatingTail

        let switcherTitle = sectionTitle("App switcher")
        takeoverBox.target = self
        takeoverBox.action = #selector(takeoverChanged)
        let takeoverNote = note("Replaces the macOS Cmd+Tab switcher with AltTab. Option+Tab keeps switching windows. The macOS switcher comes back when AltTab quits.")
        for radio in [cmdWindowsRadio, cmdAppsRadio] {
            radio.target = self
            radio.action = #selector(commandTabModeChanged)
        }
        let modeRadios = NSStackView(views: [showsLabel, cmdWindowsRadio, cmdAppsRadio])
        modeRadios.orientation = .vertical
        modeRadios.alignment = .leading
        modeRadios.spacing = 4
        modeRadios.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        for radio in [allWindowsRadio, recentWindowRadio] {
            radio.target = self
            radio.action = #selector(bringModeChanged)
        }
        layoutPopup.addItems(withTitles: ["List", "Icons (like macOS)"])
        layoutPopup.target = self
        layoutPopup.action = #selector(layoutChanged)
        let layoutRow = NSStackView(views: [layoutLabel, layoutPopup])
        layoutRow.spacing = 8
        let radios = NSStackView(views: [layoutRow, bringLabel, allWindowsRadio, recentWindowRadio])
        radios.orientation = .vertical
        radios.alignment = .leading
        radios.spacing = 4
        radios.setCustomSpacing(8, after: layoutRow)
        radios.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let generalTitle = sectionTitle("General")
        allScreensBox.target = self
        allScreensBox.action = #selector(allScreensChanged)
        let allScreensNote = note("With multiple displays, show the switcher on every screen. When off, it appears only on the screen with the mouse pointer.")
        loginBox.target = self
        loginBox.action = #selector(loginChanged)

        let stack = NSStackView(views: [fontTitle, fontRow, preview, separator(),
                                        switcherTitle, takeoverBox, takeoverNote, modeRadios, radios, separator(),
                                        generalTitle, allScreensBox, allScreensNote, loginBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: preview)
        stack.setCustomSpacing(10, after: modeRadios)
        stack.setCustomSpacing(14, after: radios)
        return padded(stack)
    }

    @objc private func fontSizeChanged() {
        Settings.fontSize = CGFloat(slider.doubleValue.rounded())
        sync()
    }

    @objc private func resetFontSize() {
        Settings.fontSize = CGFloat(Settings.defaultFontSize)
        sync()
    }

    @objc private func takeoverChanged() {
        Settings.commandTabTakeover = takeoverBox.state == .on
        sync()
        onChange?()
    }

    @objc private func commandTabModeChanged(_ sender: NSButton) {
        Settings.commandTabMode = sender == cmdAppsRadio ? .apps : .windows
        sync()
        onChange?()
    }

    @objc private func layoutChanged() {
        Settings.appSwitcherLayout = layoutPopup.indexOfSelectedItem == 1 ? .icons : .list
        sync()
    }

    @objc private func bringModeChanged(_ sender: NSButton) {
        Settings.appSwitchBringsAllWindows = sender == allWindowsRadio
        sync()
    }

    @objc private func allScreensChanged() {
        Settings.showOnAllScreens = allScreensBox.state == .on
        sync()
    }

    @objc private func loginChanged() {
        let service = SMAppService.mainApp
        do {
            if loginBox.state == .on { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("AltTab: launch at login failed: \(error)")
        }
        sync()
    }

    private func sync() {
        let size = Settings.fontSize
        slider.doubleValue = Double(size)
        valueLabel.stringValue = "\(Int(size)) pt"
        preview.font = .systemFont(ofSize: size)
        takeoverBox.state = Settings.commandTabTakeover ? .on : .off
        allWindowsRadio.state = Settings.appSwitchBringsAllWindows ? .on : .off
        recentWindowRadio.state = Settings.appSwitchBringsAllWindows ? .off : .on
        let takeover = Settings.commandTabTakeover, apps = Settings.commandTabMode == .apps
        cmdWindowsRadio.state = apps ? .off : .on
        cmdAppsRadio.state = apps ? .on : .off
        cmdWindowsRadio.isEnabled = takeover
        cmdAppsRadio.isEnabled = takeover
        showsLabel.textColor = takeover ? .labelColor : .disabledControlTextColor
        // Only the app list brings an app forward, so this applies to Cmd+Tab in app mode.
        allWindowsRadio.isEnabled = takeover && apps
        recentWindowRadio.isEnabled = takeover && apps
        layoutPopup.selectItem(at: Settings.appSwitcherLayout == .icons ? 1 : 0)
        layoutPopup.isEnabled = takeover && apps
        layoutLabel.textColor = takeover && apps ? .labelColor : .disabledControlTextColor
        bringLabel.textColor = takeover && apps ? .labelColor : .disabledControlTextColor
        allScreensBox.state = Settings.showOnAllScreens ? .on : .off
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: About

    private func aboutView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: "AltTab")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { v in
            "Version \(v)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
        } ?? "Development build"
        let versionLabel = note(version)
        let tagline = NSTextField(labelWithString: "Switch between windows, not apps.")
        let link = NSButton(title: "", target: self, action: #selector(openRepo))
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: "github.com/sr3d/AltTab", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 13),
        ])
        link.toolTip = Self.repoURL.absoluteString
        let license = note("MIT License · © 2026 Alex Le")

        let stack = NSStackView(views: [icon, name, versionLabel, tagline, link, license])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(12, after: versionLabel)
        stack.setCustomSpacing(12, after: link)
        return padded(stack)
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(Self.repoURL)
    }

    // MARK: Helpers

    private func item(_ label: String, symbol: String, _ view: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.view = view
        controller.preferredContentSize = view.fittingSize
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private func padded(_ stack: NSStackView) -> NSView {
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        return container
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = contentWidth
        return label
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }
}
