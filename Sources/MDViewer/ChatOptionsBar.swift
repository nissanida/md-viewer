import AppKit
import MDViewerCore

/// The row under the message box: which model Claude uses, how much effort it
/// puts in, and Auto mode. Choices apply from the next message.
@MainActor
final class ChatOptionsBar: NSView {
    var onChange: ((ChatSettings) -> Void)?

    private(set) var settings = ChatSettings()
    private var models: [ClaudeModel] = []

    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoSwitch = NSSwitch()
    private let autoLabel = NSTextField(labelWithString: "Auto")

    /// Shown until Claude Code lists the account's models (as a Pro plan had them in Claude Code 2.1.158).
    static let fallbackModels = [
        ClaudeModel(value: "default", displayName: "Default (recommended)", description: nil,
                    effortLevels: ["low", "medium", "high", "max"], supportsAutoMode: true),
        ClaudeModel(value: "opus", displayName: "Opus", description: nil,
                    effortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAutoMode: true),
        ClaudeModel(value: "haiku", displayName: "Haiku", description: nil, effortLevels: [], supportsAutoMode: false),
    ]

    private static let effortNames = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra High", "max": "Max"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        for popup in [modelPopup, effortPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.isBordered = false
            popup.target = self
        }
        modelPopup.action = #selector(modelChosen)
        effortPopup.action = #selector(effortChosen)
        modelPopup.setAccessibilityLabel("Model")
        effortPopup.setAccessibilityLabel("Effort")

        autoSwitch.controlSize = .mini
        autoSwitch.target = self
        autoSwitch.action = #selector(autoToggled)
        autoSwitch.setAccessibilityLabel("Auto mode")
        autoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoLabel.textColor = .secondaryLabelColor
        let autoTip = "Auto mode: Claude approves routine actions by itself and asks only about risky ones. Off: Claude asks before anything beyond the open document."
        autoSwitch.toolTip = autoTip
        autoLabel.toolTip = autoTip

        let stack = NSStackView(views: [modelPopup, effortPopup, NSView(), autoLabel, autoSwitch])
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
        modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        modelPopup.removeAllItems()
        var listed = models
        // A choice Claude Code no longer lists stays visible, so it can be changed back.
        if chosenModel == nil { listed.append(ClaudeModel(value: settings.model, displayName: settings.model, description: nil, effortLevels: [], supportsAutoMode: false)) }
        for model in listed {
            modelPopup.addItem(withTitle: model.displayName.replacingOccurrences(of: " (recommended)", with: ""))
            modelPopup.lastItem?.representedObject = model.value
            modelPopup.lastItem?.toolTip = model.description
        }
        modelPopup.selectItem(at: listed.firstIndex { $0.value == settings.model } ?? 0)
        modelPopup.toolTip = "Model: \(chosenModel?.description ?? settings.model)"

        let levels = chosenModel?.effortLevels ?? []
        effortPopup.removeAllItems()
        effortPopup.addItem(withTitle: "Default Effort")
        for level in levels {
            effortPopup.addItem(withTitle: "\(Self.effortNames[level] ?? level.capitalized) Effort")
            effortPopup.lastItem?.representedObject = level
        }
        effortPopup.selectItem(at: settings.effort.flatMap { levels.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        effortPopup.isHidden = levels.isEmpty
        effortPopup.toolTip = "How much effort Claude puts into each answer. More effort is slower and uses more of your plan."

        let autoAvailable = chosenModel?.supportsAutoMode ?? true
        autoSwitch.isEnabled = autoAvailable
        autoSwitch.state = settings.autoMode && autoAvailable ? .on : .off
        autoLabel.textColor = autoAvailable ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func modelChosen() {
        guard let value = modelPopup.selectedItem?.representedObject as? String else { return }
        settings.model = value
        // Choices the new model can't take are dropped, so what's shown is what applies.
        if let effort = settings.effort, chosenModel?.effortLevels.contains(effort) != true { settings.effort = nil }
        if chosenModel?.supportsAutoMode == false { settings.autoMode = false }
        changed()
    }

    @objc private func effortChosen() {
        settings.effort = effortPopup.selectedItem?.representedObject as? String
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
