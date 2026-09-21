import AppKit

/// Small Preferences window: switcher font size with a live preview.
/// Changes are saved immediately and apply the next time the switcher opens.
final class PreferencesWindow: NSWindowController {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "Sample window title  —  Sublime Text")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 130),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "AltTab Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        sync(to: Settings.fontSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        sync(to: Settings.fontSize)
        window?.center()
        // We're a menu-bar (accessory) app, so bring ourselves forward for the window to get focus.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Font size")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        slider.minValue = Settings.fontSizeRange.lowerBound
        slider.maxValue = Settings.fontSizeRange.upperBound
        slider.numberOfTickMarks = Int(Settings.fontSizeRange.upperBound - Settings.fontSizeRange.lowerBound) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetFontSize))
        reset.bezelStyle = .rounded

        preview.lineBreakMode = .byTruncatingTail
        let note = NSTextField(labelWithString: "Applies the next time you open the switcher.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        for v in [title, slider, valueLabel, reset, preview, note] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            slider.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            valueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueLabel.widthAnchor.constraint(equalToConstant: 44),
            reset.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            reset.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            note.topAnchor.constraint(greaterThanOrEqualTo: preview.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    @objc private func sliderChanged() {
        let size = CGFloat(slider.doubleValue.rounded())
        Settings.fontSize = size
        sync(to: size)
    }

    @objc private func resetFontSize() {
        Settings.fontSize = CGFloat(Settings.defaultFontSize)
        sync(to: Settings.fontSize)
    }

    private func sync(to size: CGFloat) {
        slider.doubleValue = Double(size)
        valueLabel.stringValue = "\(Int(size)) pt"
        preview.font = .systemFont(ofSize: size)
    }
}
