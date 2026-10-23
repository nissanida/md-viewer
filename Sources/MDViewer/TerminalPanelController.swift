import AppKit
import MDViewerCore
@preconcurrency import SwiftTerm

/// The terminal panel: the user's shell in a real pseudo-terminal, with a
/// one-click way to start Claude Code in the open folder (usually the project).
///
/// The shell starts as a login shell, so it loads the same profile and PATH as
/// a new Terminal.app window. The panel is a native view with no connection to
/// the document web views, so nothing in a document can type into it.
@MainActor
final class TerminalPanelController: NSViewController, @preconcurrency LocalProcessTerminalViewDelegate {
    var onHide: (() -> Void)?

    private(set) var folder: URL?
    private(set) var terminal: LocalProcessTerminalView?
    private(set) var isShellRunning = false

    /// How the user's shell resolves `claude` (a path or alias); nil until found.
    private var claudeCommand: String?
    private var stateTimer: Timer?
    private var keyMonitor: Any?

    private let folderLabel = NSTextField(labelWithString: "")
    private let claudeButton = NSButton()
    private let messageSlot = NSStackView()
    private let terminalContainer = NSView()

    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    // MARK: Layout

    override func loadView() {
        let root = AppearanceView()
        root.onAppearanceChange = { [weak self] in
            if let terminal = self?.terminal { self?.applyColors(to: terminal) }
        }

        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        claudeButton.title = "Start Claude Code"
        claudeButton.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        claudeButton.imagePosition = .imageLeading
        claudeButton.controlSize = .small
        claudeButton.bezelStyle = .rounded
        claudeButton.target = self
        claudeButton.action = #selector(startClaudeClicked)
        claudeButton.toolTip = "Run claude in this folder (⌃⇧`)"

        let newShell = iconButton("arrow.clockwise", "New shell in the open folder", #selector(newShellClicked))
        let hide = iconButton("chevron.down", "Hide terminal (⌃`)", #selector(hideClicked))

        let header = NSStackView(views: [icon, folderLabel, NSView(), claudeButton, newShell, hide])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        messageSlot.orientation = .vertical

        for view in [header, messageSlot, terminalContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            messageSlot.topAnchor.constraint(equalTo: header.bottomAnchor),
            messageSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            messageSlot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: messageSlot.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateHeader()

        // Look up `claude` in the background so the button responds instantly.
        Task { _ = await resolveClaude() }
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        return button
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHeader() }
        }
        installKeyMonitor()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stateTimer?.invalidate()
        stateTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Shell

    /// Starts a shell in `folder`, unless one is already running.
    func ensureShell(in folder: URL) {
        if !isShellRunning { startShell(in: folder) }
    }

    /// Starts a fresh shell in `folder`, ending the current one.
    func startShell(in folder: URL) {
        stopShell()
        _ = view // make sure the panel is built
        self.folder = folder
        showMessage(nil)

        let options = TerminalOptions(scrollback: 10_000)
        let terminal = LocalProcessTerminalView(frame: terminalContainer.bounds, font: Self.font, options: options)
        terminal.processDelegate = self
        terminal.optionAsMetaKey = true // Option+Return inserts a newline in Claude Code
        terminal.setAccessibilityLabel("Terminal")
        applyColors(to: terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 6),
            terminal.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 2),
            terminal.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])
        self.terminal = terminal

        // A leading "-" in the program name makes the shell a login shell.
        let shell = ShellEnvironment.loginShell()
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: ShellEnvironment.terminalEnvironment(from: ProcessInfo.processInfo.environment),
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: folder.path(percentEncoded: false)
        )
        isShellRunning = true
        updateHeader()
        if Preferences.autoStartClaude { startClaude() }
    }

    func stopShell() {
        // Closing the pseudo-terminal hangs up the shell and everything running in it.
        terminal?.terminate()
        terminal?.removeFromSuperview()
        terminal = nil
        isShellRunning = false
    }

    func focus() {
        if let terminal { view.window?.makeFirstResponder(terminal) }
    }

    /// Whether the shell is waiting at its prompt (nothing else is running in it).
    var isShellIdle: Bool {
        guard isShellRunning, let process = terminal?.process, process.childfd >= 0 else { return false }
        return tcgetpgrp(process.childfd) == process.shellPid
    }

    /// Whether a program (such as Claude Code) is running in the shell.
    var isBusy: Bool { isShellRunning && !isShellIdle }

    // MARK: Claude Code

    func startClaude() {
        guard isShellRunning else { return }
        Task {
            guard await resolveClaude() != nil else { return showInstallHelp() }
            guard isShellIdle else { return NSSound.beep() }
            terminal?.send(txt: "claude\r")
            focus()
            updateHeader()
        }
    }

    private func resolveClaude() async -> String? {
        if let claudeCommand { return claudeCommand }
        // Not cached when missing, so installing Claude Code takes effect without a restart.
        claudeCommand = await ShellEnvironment.resolveCommand("claude")
        return claudeCommand
    }

    private func showInstallHelp() {
        let command = "curl -fsSL https://claude.ai/install.sh | bash"
        let banner = BannerView(
            symbol: "info.circle",
            message: "Claude Code isn't installed, or your shell can't find the claude command. To install it, run: \(command)",
            actions: [
                ("Copy Command", {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }),
                ("Setup Guide", { NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!) }),
                ("Dismiss", { [weak self] in self?.showMessage(nil) }),
            ])
        showMessage(banner)
    }

    /// Shows a notice under the header (or clears it, with nil).
    private func showMessage(_ banner: BannerView?) {
        messageSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let banner else { return }
        messageSlot.addArrangedSubview(banner)
        banner.widthAnchor.constraint(equalTo: messageSlot.widthAnchor).isActive = true
    }

    // MARK: Sending text

    /// Sends text as a paste, so a multi-line selection doesn't run line by line.
    func paste(_ text: String) {
        guard let terminal, isShellRunning else { return }
        if terminal.getTerminal().bracketedPasteMode {
            terminal.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            terminal.send(txt: text)
        }
        focus()
    }

    /// The way to refer to `file` from the terminal: a path relative to the shell's
    /// folder, prefixed with @ so Claude Code attaches the file.
    func reference(to file: URL) -> String {
        let path = file.path(percentEncoded: false)
        var relative = path
        if let base = folder?.path(percentEncoded: false).trimmingSuffix("/"), path.hasPrefix(base + "/") {
            relative = String(path.dropFirst(base.count + 1))
        }
        let escaped = relative.replacingOccurrences(of: " ", with: "\\ ")
        return "@" + escaped + " "
    }

    // MARK: Header

    private func updateHeader() {
        guard isViewLoaded else { return }
        if let folder {
            folderLabel.stringValue = MainWindowController.displayPath(folder)
            folderLabel.toolTip = folder.path(percentEncoded: false)
        } else {
            folderLabel.stringValue = "No shell"
        }
        claudeButton.isEnabled = isShellRunning && !isBusy
        claudeButton.toolTip = isBusy ? "A program is running in the terminal" : "Run claude in this folder (⌃⇧`)"
    }

    @objc private func startClaudeClicked() { startClaude() }

    @objc private func newShellClicked() {
        if let folder { startShell(in: folder) }
        focus()
    }

    @objc private func hideClicked() { onHide?() }

    // MARK: Keys

    /// Shift+Return inserts a newline in Claude Code. Without the kitty keyboard
    /// protocol a terminal can't tell it from Return, so send ESC+Return
    /// (Option+Return), which Claude Code reads as a newline.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isShiftReturn = event.keyCode == 36 // Return
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            guard isShiftReturn else { return event }
            let handled = MainActor.assumeIsolated { self?.sendNewlineToClaude() ?? false }
            return handled ? nil : event
        }
    }

    /// Sends Option+Return if the terminal has focus and the program in it
    /// hasn't asked for the kitty keyboard protocol (which encodes Shift+Return itself).
    private func sendNewlineToClaude() -> Bool {
        guard let terminal, terminal.window?.firstResponder === terminal,
              terminal.getTerminal().keyboardEnhancementFlags.isEmpty else { return false }
        terminal.send(txt: "\u{1b}\r")
        return true
    }

    // MARK: Colors

    private func applyColors(to terminal: LocalProcessTerminalView) {
        let dark = terminal.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        terminal.nativeBackgroundColor = documentBackground.usingAppearance(terminal.effectiveAppearance)
        terminal.nativeForegroundColor = dark
            ? NSColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        terminal.caretColor = .controlAccentColor
        terminal.selectedTextBackgroundColor = .selectedTextBackgroundColor
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal else { return }
        isShellRunning = false
        updateHeader()
        let banner = BannerView(symbol: "terminal", message: "The shell has exited.", actions: [
            ("New Shell", { [weak self] in
                guard let self, let folder = self.folder else { return }
                self.startShell(in: folder)
                self.focus()
            }),
        ])
        showMessage(banner)
    }
}

/// A view that reports when the system switches between light and dark mode.
final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

private extension NSColor {
    /// Resolves a dynamic color for a specific appearance.
    func usingAppearance(_ appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance { resolved = self.usingColorSpace(.sRGB) ?? self }
        return resolved
    }
}
