import AppKit

/// The chat's message box. It grows with its text up to a few lines; Return
/// sends, Shift+Return or Option+Return starts a new line, and each paragraph
/// takes its own direction, so Hebrew types right to left.
@MainActor
final class ChatInputView: NSView, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    /// While Claude works, the button stops it instead of sending.
    var isWorking = false {
        didSet { updateButton() }
    }

    let textView = ChatTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private let button = NSButton()
    private var heightConstraint: NSLayoutConstraint!

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let maxLines: CGFloat = 8
    private static let fieldInset: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)

        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .natural
        textView.font = Self.font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: Self.font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.placeholder = "Ask Claude…"
        textView.setAccessibilityLabel("Message to Claude")

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        button.isBordered = false
        button.target = self
        button.action = #selector(buttonClicked)
        button.symbolConfiguration = .init(pointSize: 20, weight: .regular)

        for view in [scrollView, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: lineHeight(lines: 1))
        // The text and the button sit inside a rounded field (drawn in draw(_:)).
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.fieldInset + 8),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.fieldInset + 5),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Self.fieldInset + 5)),
            scrollView.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -4),
            heightConstraint,
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.fieldInset + 5)),
            button.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -1),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        updateButton()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    override func draw(_ dirtyRect: NSRect) {
        let field = NSBezierPath(roundedRect: bounds.insetBy(dx: Self.fieldInset, dy: Self.fieldInset), xRadius: 9, yRadius: 9)
        NSColor.textBackgroundColor.setFill()
        field.fill()
        NSColor.separatorColor.setStroke()
        field.lineWidth = 1
        field.stroke()
    }

    override func layout() {
        super.layout()
        fitHeight()
    }

    // MARK: Sending

    private func send() {
        let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isWorking else { return }
        onSend?(message)
    }

    @objc private func buttonClicked() {
        if isWorking { onStop?() } else { send() }
    }

    private func updateButton() {
        let (symbol, tip) = isWorking ? ("stop.circle.fill", "Stop") : ("arrow.up.circle.fill", "Send (Return)")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.contentTintColor = isWorking ? .labelColor : .controlAccentColor
        button.isEnabled = isWorking || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        textView.needsDisplay = true // the placeholder
        updateButton()
        fitHeight()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if textView.hasMarkedText() { return false } // Return confirms an input method's text
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            send()
        }
        return true
    }

    // MARK: Height

    private func lineHeight(lines: CGFloat) -> CGFloat {
        let line = (textView.layoutManager?.defaultLineHeight(for: Self.font) ?? 16)
        return ceil(line * lines + textView.textContainerInset.height * 2)
    }

    private func fitHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        let height = min(max(ceil(used), lineHeight(lines: 1)), lineHeight(lines: Self.maxLines))
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }
}

/// A text view that shows a hint while it is empty.
final class ChatTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
