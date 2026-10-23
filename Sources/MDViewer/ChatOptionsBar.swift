import AppKit
import MDViewerCore

/// The row under the message box: which model Claude uses, how much effort it
/// puts in, and Auto mode. Choices apply from the next message.
@MainActor
final class ChatOptionsBar: NSView {
    var onChange: ((ChatSettings) -> Void)?

    private(set) var settings = ChatSettings()
    private var models: [ClaudeModel] = []

    private let modelPill = ChatPillButton()
    private let effortPill = ChatPillButton()
    private let autoSwitch = NSSwitch()
    private let autoLabel = NSTextField(labelWithString: "Auto")

    /// Shown until Claude Code lists the account's models (as a Pro plan had them in Claude Code 2.1.158).
    static let fallbackModels = [
        ClaudeModel(value: "default", displayName: "Default (recommended)", description: "Sonnet 4.6 · Best for everyday tasks",
                    effortLevels: ["low", "medium", "high", "max"], supportsAutoMode: true),
        ClaudeModel(value: "opus", displayName: "Opus", description: "Opus 4.8 · Most capable for complex work",
                    effortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAutoMode: true),
        ClaudeModel(value: "haiku", displayName: "Haiku", description: "Haiku 4.5 · Fastest for quick answers",
                    effortLevels: [], supportsAutoMode: false),
    ]

    private static let effortNames = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra High", "max": "Max"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        modelPill.setAccessibilityLabel("Model")
        effortPill.icon = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        effortPill.setAccessibilityLabel("Effort")
        effortPill.toolTip = "Effort: how much Claude puts into each answer. More effort is slower and uses more of your plan."

        autoSwitch.controlSize = .mini
        autoSwitch.target = self
        autoSwitch.action = #selector(autoToggled)
        autoSwitch.setAccessibilityLabel("Auto mode")
        autoLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        autoLabel.textColor = .secondaryLabelColor
        let autoTip = "Auto mode: Claude approves routine actions by itself and asks only about risky ones. Off: Claude asks before anything beyond the open document."
        autoSwitch.toolTip = autoTip
        autoLabel.toolTip = autoTip

        let stack = NSStackView(views: [modelPill, effortPill, NSView(), autoLabel, autoSwitch])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        modelPill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the choices for the models Claude Code offers (or, before it has
    /// said, the usual ones).
    func show(_ settings: ChatSettings, models: [ClaudeModel]) {
        self.settings = settings
        self.models = models.isEmpty ? Self.fallbackModels : models
        rebuild()
    }

    private var chosenModel: ClaudeModel? {
        models.first { $0.value == settings.model }
    }

    private func rebuild() {
        // Model: the name of the model behind each choice, with what it is good for.
        let modelMenu = NSMenu()
        modelMenu.addItem(.sectionHeader(title: "Model"))
        var listed = models
        // A choice Claude Code no longer lists stays visible, so it can be changed back.
        if chosenModel == nil {
            listed.append(ClaudeModel(value: settings.model, displayName: settings.model, description: nil, effortLevels: [], supportsAutoMode: false))
        }
        for model in listed {
            let details = [model.value == "default" ? "Default" : nil, model.summary].compactMap { $0 }.joined(separator: " · ")
            modelMenu.addItem(choice(model.name, details: details, value: model.value, chosen: model.value == settings.model,
                                     action: #selector(modelChosen(_:))))
        }
        modelPill.title = chosenModel?.name ?? settings.model
        modelPill.choices = modelMenu
        modelPill.toolTip = [chosenModel?.name, chosenModel?.summary].compactMap { $0 }.joined(separator: ": ")

        // Effort: only the levels the chosen model has.
        let levels = chosenModel?.effortLevels ?? []
        let effortMenu = NSMenu()
        effortMenu.addItem(.sectionHeader(title: "Effort"))
        effortMenu.addItem(choice("Default", details: "The model's own setting", value: nil, chosen: settings.effort == nil,
                                  action: #selector(effortChosen(_:))))
        for level in levels {
            effortMenu.addItem(choice(Self.effortNames[level] ?? level.capitalized, details: nil, value: level,
                                      chosen: settings.effort == level, action: #selector(effortChosen(_:))))
        }
        let chosenLevel = settings.effort.flatMap { levels.contains($0) ? Self.effortNames[$0] ?? $0 : nil }
        effortPill.title = chosenLevel ?? "Default"
        effortPill.choices = effortMenu
        effortPill.isHidden = levels.isEmpty

        let autoAvailable = chosenModel?.supportsAutoMode ?? true
        autoSwitch.isEnabled = autoAvailable
        autoSwitch.state = settings.autoMode && autoAvailable ? .on : .off
        autoLabel.textColor = autoAvailable ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func choice(_ title: String, details: String?, value: String?, chosen: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = chosen ? .on : .off
        if let details, !details.isEmpty {
            if #available(macOS 14.4, *) { item.subtitle = details } else { item.toolTip = details }
        }
        return item
    }

    @objc private func modelChosen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        settings.model = value
        // Choices the new model can't take are dropped, so what's shown is what applies.
        if let effort = settings.effort, chosenModel?.effortLevels.contains(effort) != true { settings.effort = nil }
        if chosenModel?.supportsAutoMode == false { settings.autoMode = false }
        changed()
    }

    @objc private func effortChosen(_ sender: NSMenuItem) {
        settings.effort = sender.representedObject as? String
        changed()
    }

    @objc private func autoToggled() {
        settings.autoMode = autoSwitch.state == .on
        changed()
    }

    private func changed() {
        rebuild()
        onChange?(settings)
    }

    /// For the automation hook: choose as if from the menus.
    func choose(_ settings: ChatSettings) {
        self.settings = settings
        changed()
    }
}

/// A small rounded button in the chat's own quiet style: a soft capsule with
/// a title. With `choices` it opens that menu (and shows a chevron); without,
/// it runs `onPress`.
@MainActor
final class ChatPillButton: NSView {
    var choices: NSMenu? {
        didSet {
            chevron.isHidden = choices == nil
            setAccessibilityRole(choices == nil ? .button : .popUpButton)
        }
    }

    var onPress: (() -> Void)?

    var title = "" {
        didSet { label.stringValue = title; setAccessibilityValue(title) }
    }

    /// Template symbols are tinted like the title; colored images keep their color.
    var icon: NSImage? {
        didSet { iconView.image = icon; iconView.isHidden = icon == nil }
    }

    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let chevron = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.isHidden = true
        iconView.contentTintColor = .secondaryLabelColor
        chevron.isHidden = true
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        chevron.contentTintColor = .tertiaryLabelColor

        let stack = NSStackView(views: [iconView, label, chevron])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = pressed ? 0.16 : hovering ? 0.10 : 0.06
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        if choices == nil { return } // a plain button acts when the mouse comes up over it
        press()
        pressed = false
    }

    override func mouseUp(with event: NSEvent) {
        guard choices == nil, pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    /// Opens the menu with the current choice over the button, like a pop-up
    /// button, or runs the button's action.
    private func press() {
        guard let choices else { return onPress?() ?? () }
        let current = choices.items.first { $0.state == .on }
        choices.popUp(positioning: current, at: NSPoint(x: 0, y: bounds.height - 1), in: self)
        hovering = false
    }
}
