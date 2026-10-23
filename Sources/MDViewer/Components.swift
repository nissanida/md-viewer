import AppKit

/// Background color shared by the preview page and the editor, so switching views doesn't flash.
let documentBackground = NSColor(name: "documentBackground") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1F / 255, alpha: 1)
        : NSColor(srgbRed: 0xFD / 255, green: 0xFD / 255, blue: 0xFC / 255, alpha: 1)
}

// MARK: - Source editor

/// The raw-text view used for Source and Edit modes: plain text, no smart
/// quotes or autocorrect, the native find bar, and per-paragraph text direction.
@MainActor
final class SourceEditor: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = EditorTextView(frame: .zero)
    var onChange: (() -> Void)?

    private let baseFontSize: CGFloat = 13

    override init() {
        super.init()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = documentBackground
        scrollView.documentView = textView

        textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 28, height: 24)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.backgroundColor = documentBackground
        textView.textColor = .textColor
        textView.setAccessibilityLabel("Source")
        setZoom(1)
    }

    var text: String { textView.string }

    /// Replaces the whole text, keeping the selection and scroll position when
    /// possible (the same file reloaded) and clearing undo history.
    func setText(_ newText: String, keepPosition: Bool) {
        let selection = textView.selectedRange()
        let visible = scrollView.contentView.bounds.origin
        textView.string = newText
        // Undo must not bring back text from before a reload or another file.
        textView.undoManager?.removeAllActions()
        if keepPosition {
            let length = (newText as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            scrollView.contentView.scroll(to: visible)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func setZoom(_ zoom: Double) {
        let font = NSFont.monospacedSystemFont(ofSize: baseFontSize * zoom, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.baseWritingDirection = .natural // each paragraph's direction follows its text
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]
        if let storage = textView.textStorage {
            let range = NSRange(location: 0, length: storage.length)
            storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: range)
        }
    }

    func selectedText() -> String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    func textDidChange(_ notification: Notification) {
        onChange?()
    }
}

/// Text view that opens dropped markdown and HTML files instead of inserting their paths.
final class EditorTextView: NSTextView {
    var onDropFiles: (([URL]) -> Void)?

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty, let onDropFiles else { return super.performDragOperation(sender) }
        onDropFiles(files)
        return true
    }
}

// MARK: - Find bar

/// A slim find bar for the previews (the source editor uses the native one).
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    var onSearch: ((_ text: String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let status = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find in document"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(findNext)
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let previous = button("chevron.left", "Previous match (⇧⌘G)", #selector(findPrevious))
        let next = button("chevron.right", "Next match (⌘G)", #selector(findNext))
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.controlSize = .small
        done.bezelStyle = .rounded
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [field, previous, next, status, NSView(), done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func show(found: Bool?) {
        status.stringValue = found == false ? "Not found" : ""
    }

    @objc func findNext() { search(backwards: false) }
    @objc func findPrevious() { search(backwards: true) }
    @objc func close() { onClose?() }

    private func search(backwards: Bool) {
        pending?.cancel()
        let text = field.stringValue
        guard !text.isEmpty else { return show(found: nil) }
        onSearch?(text, backwards)
    }

    // Search as you type, after a short pause.
    func controlTextDidChange(_ obj: Notification) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search(backwards: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.contains(.shift) {
            findPrevious()
            return true
        }
        return false
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = tip
        return button
    }
}

// MARK: - Banner

/// A one-line notice above the document, with optional buttons.
@MainActor
final class BannerView: NSView {
    enum Tone { case info, warning }

    private let tone: Tone

    init(symbol: String, message: String, tone: Tone = .info, actions: [(String, () -> Void)] = []) {
        self.tone = tone
        super.init(frame: .zero)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = tone == .warning ? .systemOrange : .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [icon, label, NSView()]
        for (title, handler) in actions {
            let button = ClosureButton(title: title, handler: handler)
            button.controlSize = .small
            button.bezelStyle = .rounded
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor = tone == .warning ? .systemOrange : .controlAccentColor
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        tint.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler() }
}

// MARK: - Empty state

/// Shown when no document is open: a quiet hint, and a drop target.
@MainActor
final class EmptyStateView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    private let title = NSTextField(labelWithString: "")

    /// With a folder open, point to its file list instead of the Open command.
    var folderIsOpen = false {
        didSet { title.stringValue = folderIsOpen ? "Choose a file in the sidebar" : "Open a markdown or HTML file" }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .ultraLight)
        icon.contentTintColor = .tertiaryLabelColor

        title.stringValue = "Open a markdown or HTML file"
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor

        let hint = NSTextField(labelWithString: "⌘O  Open File     ⇧⌘O  Open Folder     or drop it here")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        documentBackground.setFill()
        dirtyRect.fill()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        onDropFiles?(files)
        return true
    }
}
