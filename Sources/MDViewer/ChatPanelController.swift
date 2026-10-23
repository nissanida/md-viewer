import AppKit
import MDViewerCore

/// The Claude symbol (web/claude-symbol.svg) for the chat's toolbar button and
/// header, drawn in Claude's orange. It is Anthropic's trademark: fine in your
/// own copy, but publishing the app with it needs Anthropic's permission.
@MainActor
enum ClaudeSymbol {
    static let color = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    /// The symbol in orange at any scale. A colored image rather than a tinted
    /// template, since toolbars ignore tints in windows that aren't in front.
    static func image(size: CGFloat) -> NSImage {
        guard let svg = NSImage(contentsOf: AppResources.webRoot.appending(path: "claude-symbol.svg")) else {
            return NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")!
        }
        nonisolated(unsafe) let symbol = svg // only drawn on the main thread
        let orange = color
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            symbol.draw(in: rect)
            orange.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.accessibilityDescription = "Claude"
        return image
    }
}

/// What the chat needs from the window: the document, where Claude works, and
/// a few actions.
@MainActor
protocol ChatHost: AnyObject {
    /// The document the chat is about, if one is open.
    var chatDocument: URL? { get }
    /// Where Claude Code works: the folder open in the sidebar, else the document's folder.
    var chatFolder: URL { get }
    /// Saves unsaved edits, so Claude works on what the user sees. False if saving failed.
    func saveDocumentForChat() -> Bool
    /// The text selected in the document, if any.
    func chatSelection() async -> String?
    func openChatLink(_ action: LinkAction)
    /// Opens the terminal panel and runs a command at its prompt.
    func runInTerminal(_ command: String)
}

/// The chat panel: ask Claude to change the open document. Runs Claude Code in
/// stream-json mode (see docs/CHAT_DESIGN.md), shows its work as a transcript,
/// allows edits to the open document by itself, asks the user about anything
/// else, and offers to undo Claude's change.
@MainActor
final class ChatPanelController: NSViewController {
    weak var host: ChatHost?
    var onHide: (() -> Void)?
    /// Claude needs an answer (an approval): the panel must be visible.
    var onNeedsAttention: (() -> Void)?

    /// Whether Claude is working on a message.
    private(set) var isWorking = false

    // The Claude Code session.
    private var claude: ClaudeProcess?
    private var claudeReady = false
    /// Goes up with each process, so whatever an ended one still says is ignored.
    private var generation = 0
    private var sessionID: String?
    /// The first message, waiting while Claude Code starts.
    private var queuedMessage: String?

    // The message Claude is working on.
    private var turn = 0
    private var turnDocument: URL?
    private var turnSnapshot: Data?
    private var stopRequested = false
    private var approvals: [ApprovalRequest] = []

    // After a message.
    private var lastChange: DocumentChange?
    private var undoneDocument: URL?
    private var needsSignIn = false
    private var needsInstall = false

    private var transcript = ChatTranscript(folder: nil)
    private var pendingItemIDs: [String] = []
    private var flushScheduled = false

    private let documentLabel = NSTextField(labelWithString: "")
    private let transcriptView = ChatTranscriptView()
    private let noticeSlot = NSStackView()
    private var shownNotice = ""
    private let input = ChatInputView()

    private struct DocumentChange {
        let file: URL
        let before: Data
        let after: Data
    }

    private static let initializeRequest = "init"
    private static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    // MARK: Layout

    override func loadView() {
        let title = NSTextField(labelWithString: "CHAT")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        documentLabel.font = .systemFont(ofSize: 11)
        documentLabel.textColor = .tertiaryLabelColor
        documentLabel.lineBreakMode = .byTruncatingMiddle
        documentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let symbol = NSImageView(image: ClaudeSymbol.image(size: 13))
        let newChat = iconButton("square.and.pencil", "New Chat", #selector(newChatClicked))
        let hide = iconButton("xmark", "Hide Chat (⌃⌘C)", #selector(hideClicked))
        let header = NSStackView(views: [symbol, title, documentLabel, NSView(), newChat, hide])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 8)

        noticeSlot.orientation = .vertical
        noticeSlot.spacing = 0

        transcriptView.onLink = { [weak self] in self?.host?.openChatLink($0) }
        input.onSend = { [weak self] in self?.send($0) }
        input.onStop = { [weak self] in self?.stop() }

        let root = NSView()
        let webView = transcriptView.webView
        for view in [header, webView, noticeSlot, input] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            noticeSlot.topAnchor.constraint(equalTo: webView.bottomAnchor),
            noticeSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            noticeSlot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            input.topAnchor.constraint(equalTo: noticeSlot.bottomAnchor),
            input.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            input.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        documentChanged()
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        return button
    }

    /// The window's document changed: show its name.
    func documentChanged() {
        guard isViewLoaded else { return }
        let document = host?.chatDocument
        documentLabel.stringValue = document?.lastPathComponent ?? ""
        documentLabel.toolTip = document?.path(percentEncoded: false)
    }

    func focus() {
        input.focus()
    }

    @objc private func newChatClicked() { newChat() }
    @objc private func hideClicked() { onHide?() }

    // MARK: Sending

    func send(_ text: String) {
        guard !isWorking, let host else { return }
        // Claude reads the file from disk, so unsaved edits are saved first.
        guard host.saveDocumentForChat() else { return }
        isWorking = true
        turn += 1
        let turn = turn
        stopRequested = false
        needsSignIn = false
        needsInstall = false
        input.text = ""
        let document = host.chatDocument
        turnDocument = document
        turnSnapshot = document.flatMap { try? Data(contentsOf: $0) }
        updateControls()

        Task {
            let selection = await host.chatSelection()
            guard isWorking, self.turn == turn else { return } // stopped or started over meanwhile
            // A new chat works in the window's folder; a session keeps its own,
            // so it can be resumed there if Claude Code has to start again.
            if claude == nil, sessionID == nil || transcript.folder == nil {
                transcript.folder = host.chatFolder
                transcriptView.folder = transcript.folder
            }
            let message = ChatContext.message(text, document: document, folder: transcript.folder,
                                              selection: selection, undoneDocument: undoneDocument)
            undoneDocument = nil
            show([transcript.addUserMessage(text, quote: selection)])
            if let claude, claudeReady {
                claude.send(ClaudeInput.userMessage(message))
            } else {
                queuedMessage = message
                if claude == nil { startClaude() }
            }
            updateControls()
        }
    }

    func stop() {
        guard isWorking else { return }
        stopRequested = true
        for request in approvals {
            claude?.send(ClaudeInput.deny(requestID: request.requestID, message: "The user stopped this request.", interrupt: true))
        }
        approvals.removeAll()
        guard let claude, claudeReady else {
            // Still starting: drop the message along with the half-started session.
            endSession()
            return finishTurn(nil)
        }
        claude.send(ClaudeInput.interrupt(requestID: "stop-\(turn)"))
        let turn = turn
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isWorking, self.turn == turn else { return }
                // Claude Code didn't wrap up: end it. The next message resumes the session.
                self.endSession()
                self.finishTurn(nil)
            }
        }
        updateControls()
    }

    func newChat() {
        endSession()
        sessionID = nil
        isWorking = false
        turnDocument = nil
        turnSnapshot = nil
        stopRequested = false
        approvals.removeAll()
        queuedMessage = nil
        lastChange = nil
        undoneDocument = nil
        needsSignIn = false
        needsInstall = false
        transcript.reset()
        pendingItemIDs.removeAll()
        transcriptView.reset()
        updateControls()
        input.focus()
    }

    /// Ends Claude Code. Anything it still says is ignored.
    func endSession() {
        generation += 1
        claude?.terminate()
        claude = nil
        claudeReady = false
    }

    // MARK: Claude Code

    private func startClaude() {
        generation += 1
        let generation = generation
        let folder = transcript.folder ?? FileManager.default.homeDirectoryForCurrentUser
        Task {
            let environment = await Self.claudeEnvironment()
            guard generation == self.generation else { return } // stopped or started over meanwhile
            guard let executable = DevAutomation.claudePath ?? ShellEnvironment.findExecutable("claude", in: environment) else {
                needsInstall = true
                return finishTurn(nil)
            }
            let process = ClaudeProcess(
                executable: URL(fileURLWithPath: executable),
                arguments: ClaudeLaunch.arguments(resumeSessionID: sessionID, model: DevAutomation.claudeModel),
                environment: ClaudeLaunch.environment(from: environment), directory: folder, callbackQueue: .main,
                onEvent: { [weak self] event in
                    MainActor.assumeIsolated { self?.handle(event, from: generation) }
                },
                onExit: { [weak self] status, errorOutput in
                    MainActor.assumeIsolated { self?.claudeExited(generation, status: status, errorOutput: errorOutput) }
                })
            do {
                try process.start()
            } catch {
                show([transcript.addNotice("Claude Code couldn’t start: \(error.localizedDescription)", tone: .error)])
                return finishTurn(nil)
            }
            claude = process
            claudeReady = false
            process.send(ClaudeInput.initialize(requestID: Self.initializeRequest))
            // Claude Code answers within a second or two; don't wait forever for an answer that never comes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                MainActor.assumeIsolated { self?.claudeIsReady(generation) }
            }
            updateControls()
        }
    }

    private func claudeIsReady(_ generation: Int) {
        guard generation == self.generation, let claude, !claudeReady else { return }
        claudeReady = true
        if let message = queuedMessage {
            queuedMessage = nil
            claude.send(ClaudeInput.userMessage(message))
        }
        updateControls()
    }

    private func handle(_ event: ClaudeEvent, from generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .requestAnswered(requestID: Self.initializeRequest, error: _):
            claudeIsReady(generation)
        case .requestAnswered:
            break
        case .sessionStarted(let id, _):
            sessionID = id
        case .approvalRequested(let request):
            approve(request)
        case .approvalWithdrawn(let id):
            approvals.removeAll { $0.requestID == id }
        case .unsupportedRequest(let id, let subtype):
            claude?.send(ClaudeInput.unsupported(requestID: id, subtype: subtype))
        case .turnFinished(let result):
            finishTurn(result)
        case .failed(let kind, _):
            if kind == "authentication_failed" { needsSignIn = true }
            show(transcript.apply(event))
        default:
            show(transcript.apply(event))
        }
        updateControls()
    }

    private func claudeExited(_ generation: Int, status: Int32, errorOutput: String) {
        guard generation == self.generation else { return }
        // Ending before it was ready means it couldn't start, for example
        // because the session to resume is gone: the next message starts afresh.
        if !claudeReady { sessionID = nil }
        claude = nil
        claudeReady = false
        guard isWorking else { return }
        let detail = errorOutput.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        let message = detail.isEmpty ? "Claude Code stopped unexpectedly." : "Claude Code stopped unexpectedly:\n\(detail)"
        show([transcript.addNotice(message, tone: .error)])
        finishTurn(nil)
    }

    private func finishTurn(_ result: TurnResult?) {
        guard isWorking else { return }
        isWorking = false
        if let id = result?.sessionID { sessionID = id }
        show(transcript.finishTurn(result, stoppedByUser: stopRequested))
        stopRequested = false
        approvals.removeAll()
        queuedMessage = nil
        if let file = turnDocument, let before = turnSnapshot, let after = try? Data(contentsOf: file), after != before {
            lastChange = DocumentChange(file: file, before: before, after: after)
        }
        turnDocument = nil
        turnSnapshot = nil
        if result?.isError == true, result?.message?.contains("/login") == true { needsSignIn = true }
        updateControls()
    }

    /// The login shell's environment, as a Terminal window has it. If the
    /// shell can't be read, the app's own, with the usual install folders.
    private static var loginEnvironment: [String: String]?

    private static func claudeEnvironment() async -> [String: String] {
        if let loginEnvironment { return loginEnvironment }
        if let found = await ShellEnvironment.loginEnvironment() {
            loginEnvironment = found
            return found
        }
        var fallback = ShellEnvironment.withoutParentSession(ProcessInfo.processInfo.environment)
        fallback["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                            fallback["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        return fallback
    }

    // MARK: Approvals

    private func approve(_ request: ApprovalRequest) {
        if ChatPermissionPolicy.allowsWithoutAsking(toolName: request.toolName, input: request.input, openDocument: turnDocument) {
            claude?.send(ClaudeInput.allow(requestID: request.requestID, input: request.input))
        } else {
            approvals.append(request)
            onNeedsAttention?()
        }
    }

    private func answerApproval(allow: Bool) {
        guard !approvals.isEmpty else { return }
        let request = approvals.removeFirst()
        if allow {
            claude?.send(ClaudeInput.allow(requestID: request.requestID, input: request.input))
        } else {
            claude?.send(ClaudeInput.deny(requestID: request.requestID, message: "The user declined this action.", interrupt: false))
            if let id = request.toolUseID { show(transcript.markDenied(toolUseID: id)) }
        }
        updateControls()
    }

    // MARK: Undo and sign-in

    private func undoLastChange() {
        guard let change = lastChange else { return }
        let name = change.file.lastPathComponent
        if (try? Data(contentsOf: change.file)) != change.after {
            let alert = NSAlert()
            alert.messageText = "“\(name)” changed after Claude’s edit."
            alert.informativeText = "Undo puts back the version from before Claude’s change. Changes made since then will be lost."
            alert.addButton(withTitle: "Undo Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try change.before.write(to: change.file, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        lastChange = nil
        undoneDocument = change.file
        show([transcript.addNotice("Undid Claude’s change to \(name).", tone: .info)])
        updateControls()
    }

    private func signIn() {
        needsSignIn = false
        endSession() // the next message starts Claude Code again, signed in
        host?.runInTerminal("claude auth login")
        show([transcript.addNotice("Finish signing in in the terminal, then send your message again.", tone: .info)])
        updateControls()
    }

    // MARK: Updating the view

    private func updateControls() {
        input.isWorking = isWorking
        updateNotice()
        let streaming = transcript.items.last?.streaming == true
        let status: String? = !isWorking || streaming || !approvals.isEmpty ? nil : (claudeReady ? "Thinking" : "Starting Claude")
        transcriptView.setStatus(status)
    }

    /// Shows what needs the user: an approval first, then sign-in or install
    /// help, then the offer to undo.
    private func updateNotice() {
        let key: String
        let make: (() -> ChatNoticeView)?
        if let request = approvals.first {
            key = "approval " + request.requestID
            make = { [weak self] in
                let question = ToolStep.question(name: request.toolName, input: request.input, folder: self?.transcript.folder)
                return ChatNoticeView(symbol: "hand.raised", message: question.text, code: question.code, tone: .warning, actions: [
                    ("Deny", { self?.answerApproval(allow: false) }),
                    ("Allow", { self?.answerApproval(allow: true) }),
                ])
            }
        } else if needsSignIn {
            key = "sign in"
            make = { [weak self] in
                ChatNoticeView(symbol: "person.crop.circle.badge.exclamationmark",
                               message: "Claude Code isn’t signed in on this Mac. Sign in once in the terminal, then send your message again.",
                               tone: .warning, actions: [
                                   ("Not Now", { self?.needsSignIn = false; self?.updateControls() }),
                                   ("Sign In…", { self?.signIn() }),
                               ])
            }
        } else if needsInstall {
            key = "install"
            make = { [weak self] in
                ChatNoticeView(symbol: "info.circle",
                               message: "Claude Code isn’t installed, or MD Viewer can’t find the claude command. To install it, run this in a terminal:",
                               code: Self.installCommand, actions: [
                                   ("Setup Guide", { NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!) }),
                                   ("Copy Command", {
                                       NSPasteboard.general.clearContents()
                                       NSPasteboard.general.setString(Self.installCommand, forType: .string)
                                   }),
                                   ("Dismiss", { self?.needsInstall = false; self?.updateControls() }),
                               ])
            }
        } else if let change = lastChange, !isWorking {
            key = "undo " + change.file.path(percentEncoded: false) + String(change.after.hashValue)
            make = { [weak self] in
                ChatNoticeView(symbol: "arrow.uturn.backward.circle", message: "Claude changed \(change.file.lastPathComponent).", actions: [
                    ("Keep", { self?.lastChange = nil; self?.updateControls() }),
                    ("Undo", { self?.undoLastChange() }),
                ])
            }
        } else {
            key = ""
            make = nil
        }
        guard key != shownNotice else { return }
        shownNotice = key
        noticeSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let make else { return }
        let notice = make()
        noticeSlot.addArrangedSubview(notice)
        notice.widthAnchor.constraint(equalTo: noticeSlot.widthAnchor).isActive = true
    }

    /// Sends changed items to the page, a few at a time while text streams in.
    private func show(_ items: [ChatItem]) {
        guard !items.isEmpty else { return }
        for item in items where !pendingItemIDs.contains(item.id) { pendingItemIDs.append(item.id) }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let ids = Set(pendingItemIDs)
        pendingItemIDs.removeAll()
        transcriptView.upsert(transcript.items.filter { ids.contains($0.id) })
    }

    // MARK: Automation (development only)

    /// The chat's state as JSON, for scripts/automate.swift.
    func automationState() -> [String: Any] {
        let items = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript.items))) ?? []
        return [
            "working": isWorking,
            "ready": claudeReady,
            "items": items,
            "approvals": approvals.map { ["tool": $0.toolName, "id": $0.requestID] },
            "notice": shownNotice.split(separator: " ").first.map(String.init) ?? "",
            "input": input.text,
        ]
    }

    func typeForAutomation(_ text: String) {
        input.text = text
    }
}

/// A notice above the message box, with buttons: an approval, the offer to
/// undo, sign-in or install help. Laid out for a narrow panel: the text on
/// top, the buttons below.
@MainActor
final class ChatNoticeView: NSView {
    enum Tone { case info, warning }

    private let tone: Tone

    init(symbol: String, message: String, code: String? = nil, tone: Tone = .info, actions: [(String, () -> Void)]) {
        self.tone = tone
        super.init(frame: .zero)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = tone == .warning ? .systemOrange : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        var texts: [NSTextField] = [label]
        if let code {
            let codeLabel = NSTextField(wrappingLabelWithString: code)
            codeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            codeLabel.textColor = .secondaryLabelColor
            codeLabel.maximumNumberOfLines = 4
            codeLabel.lineBreakMode = .byTruncatingTail
            codeLabel.isSelectable = true
            texts.append(codeLabel)
        }
        // The text, and the command under it, line up past the icon.
        let column = NSStackView(views: texts)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        for text in texts {
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let top = NSStackView(views: [icon, column])
        top.alignment = .top
        top.spacing = 7

        var rows: [NSView] = [top]
        if !actions.isEmpty {
            let buttons = actions.map { title, handler in
                let button = ClosureButton(title: title, handler: handler)
                button.controlSize = .small
                button.bezelStyle = .rounded
                return button
            }
            let row = NSStackView(views: [NSView()] + buttons)
            row.spacing = 6
            rows.append(row)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor = tone == .warning ? .systemOrange : .controlAccentColor
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        tint.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
