import AppKit
import MDViewerCore
import UniformTypeIdentifiers

/// The app's single window: file sidebar, document, outline, chat and terminal
/// panel. Coordinates opening files and folders, watching them for changes, and
/// the menu and toolbar actions.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private let sidebar = SidebarViewController()
    private let documentPane = DocumentViewController()
    private let outline = OutlineViewController()
    private let terminalPanel = TerminalPanelController()
    private let chatPanel = ChatPanelController()
    private let mainSplit = NSSplitViewController()
    private let centerSplit = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem!
    private var terminalItem: NSSplitViewItem!
    private var chatItem: NSSplitViewItem!

    private(set) var rootFolder: URL?
    private var watcher: FileWatcher?
    /// The open file's path as FSEvents reports it, kept so a deletion can still be matched.
    private var watchedFilePath: String?
    private var toolbarButtons: [NSToolbarItem.Identifier: NSButton] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MD Viewer"
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        buildToolbar()

        // Size and position are remembered between launches.
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame MainWindow") != nil
        window.setFrameAutosaveName("MainWindow")
        if !hasSavedFrame {
            window.setContentSize(NSSize(width: 1080, height: 760))
            window.center()
        }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true

        let documentItem = NSSplitViewItem(viewController: documentPane)
        documentItem.minimumThickness = 160
        terminalItem = NSSplitViewItem(viewController: terminalPanel)
        terminalItem.canCollapse = true
        terminalItem.minimumThickness = 120
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(260) // the document absorbs window resizes
        centerSplit.splitView.isVertical = false
        centerSplit.splitView.dividerStyle = .thin
        centerSplit.addSplitViewItem(documentItem)
        centerSplit.addSplitViewItem(terminalItem)

        outlineItem = NSSplitViewItem(inspectorWithViewController: outline)
        outlineItem.minimumThickness = 170
        outlineItem.maximumThickness = 360
        outlineItem.canCollapse = true

        chatItem = NSSplitViewItem(inspectorWithViewController: chatPanel)
        chatItem.minimumThickness = 260
        chatItem.maximumThickness = 640
        chatItem.canCollapse = true

        mainSplit.addSplitViewItem(sidebarItem)
        mainSplit.addSplitViewItem(NSSplitViewItem(viewController: centerSplit))
        mainSplit.addSplitViewItem(outlineItem)
        mainSplit.addSplitViewItem(chatItem)
        window?.contentViewController = mainSplit

        // Panel sizes are remembered; which panels are open is restored below.
        mainSplit.splitView.autosaveName = "MainSplit"
        centerSplit.splitView.autosaveName = "CenterSplit"
        sidebarItem.isCollapsed = !Preferences.sidebarVisible
        outlineItem.isCollapsed = !Preferences.outlineVisible
        chatItem.isCollapsed = !Preferences.chatVisible
        terminalItem.isCollapsed = true

        sidebar.onOpen = { [weak self] in self?.openFile($0) }
        outline.onSelect = { [weak self] in self?.documentPane.scrollTo(anchor: $0.id) }
        terminalPanel.onHide = { [weak self] in self?.setTerminalVisible(false) }
        chatPanel.host = self
        chatPanel.onHide = { [weak self] in self?.setChatVisible(false) }
        chatPanel.onNeedsAttention = { [weak self] in
            if self?.chatItem.isCollapsed == true { self?.setChatVisible(true) }
        }
        documentPane.onStateChange = { [weak self] in self?.documentStateChanged() }
        documentPane.onOutline = { [weak self] in self?.outline.show($0) }
        documentPane.onLink = { [weak self] in self?.follow($0) }
        documentPane.onDropFiles = { [weak self] in self?.open($0) }
    }

    // MARK: Opening files and folders

    var currentFolder: URL? { documentPane.fileURL?.deletingLastPathComponent() ?? rootFolder }

    /// Opens files and folders from Finder, the Dock, drag and drop or the command line.
    func open(_ urls: [URL]) {
        guard let url = urls.first?.standardizedFileURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return showAlert("“\(url.lastPathComponent)” couldn’t be found.", detail: url.path(percentEncoded: false))
        }
        if isDirectory.boolValue { openFolder(url) } else { openFile(url) }
    }

    func openFolder(_ folder: URL) {
        guard confirmDiscardingEdits() else { return }
        setRootFolder(folder)
        remember(folder)
        setSidebarVisible(true)
        // Show the folder's README, as GitHub does (matching names the way the disk spells them).
        let entries = FolderScanner.entries(in: folder).filter { !$0.isDirectory }
        let readme = ["readme.md", "index.md", "index.html"].lazy
            .compactMap { name in entries.first { $0.name.lowercased() == name }?.url }
            .first
        if let readme {
            openFile(readme)
        } else {
            documentPane.closeDocument()
            watchedFilePath = nil
            sidebar.reveal(nil)
        }
    }

    func openFile(_ file: URL, fragment: String? = nil) {
        let file = file.standardizedFileURL
        guard DocumentKind(url: file) != nil else { return openOtherFile(file) }
        if file != documentPane.fileURL, !confirmDiscardingEdits() { return }

        // Keep the open folder when the file is inside it; otherwise browse the file's folder.
        if !isInsideRoot(file) { setRootFolder(file.deletingLastPathComponent()) }
        guard documentPane.open(file, fragment: fragment) else { return }
        watchedFilePath = canonicalPath(file)
        sidebar.reveal(file)
        remember(file)
        Preferences.lastFile = file
        showTerminalIfRemembered()
        offerToBecomeDefaultApp()
    }

    /// From the second launch on, asks once whether to make MD Viewer the default
    /// app for markdown. The first launch stays free of prompts.
    private func offerToBecomeDefaultApp() {
        guard documentPane.kind == .markdown, documentPane.tip == nil, !Preferences.defaultAppOfferAnswered,
              Preferences.launchCount >= 2, DefaultApp.canChange, !DefaultApp.isDefault(for: .markdown)
        else { return }
        documentPane.tip = BannerView(
            symbol: "doc.text",
            message: "Make MD Viewer your default app for markdown files? You can also do this later from the MD Viewer menu.",
            actions: [
                ("Make Default", { [weak self] in self?.answerDefaultAppOffer(makeDefault: true) }),
                ("No Thanks", { [weak self] in self?.answerDefaultAppOffer(makeDefault: false) }),
            ])
    }

    private func answerDefaultAppOffer(makeDefault: Bool) {
        Preferences.defaultAppOfferAnswered = true
        documentPane.tip = nil
        guard makeDefault else { return }
        Task {
            do {
                try await DefaultApp.makeDefault(for: .markdown)
            } catch {
                showAlert("MD Viewer couldn’t be made the default app.", detail: error.localizedDescription)
            }
        }
    }

    private func isInsideRoot(_ file: URL) -> Bool {
        guard let root = rootFolder?.path(percentEncoded: false).trimmingSuffix("/") else { return false }
        return file.path(percentEncoded: false).hasPrefix(root + "/")
    }

    private func setRootFolder(_ folder: URL) {
        let folder = folder.standardizedFileURL
        rootFolder = folder
        documentPane.rootFolder = folder
        sidebar.setFolder(folder)
        Preferences.lastFolder = folder
        watch(folder)
        updateTitle()
    }

    private func remember(_ url: URL) {
        Preferences.noteRecent(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url) // the Dock menu's recent items
    }

    func restoreLastSession() {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        if let folder = Preferences.lastFolder, exists(folder) { setRootFolder(folder) }
        if let file = Preferences.lastFile, exists(file) { openFile(file) }
        showTerminalIfRemembered()
    }

    func saveSession() {
        Preferences.lastFolder = rootFolder
        Preferences.lastFile = documentPane.fileURL
    }

    /// Links from documents. Local files that aren't documents open only if they
    /// are plain data (images, PDFs, text); anything that could run (apps,
    /// scripts, installers) is shown in Finder instead, so a link in a document
    /// can never launch a program.
    private func follow(_ action: LinkAction) {
        switch action {
        case .openDocument(let url, let fragment):
            if url == documentPane.fileURL, let fragment { documentPane.scrollTo(anchor: fragment) } else { openFile(url, fragment: fragment) }
        case .openFile(let url):
            openOtherFile(url)
        case .openExternal(let url):
            NSWorkspace.shared.open(url)
        case .ignore:
            break
        }
    }

    private func openOtherFile(_ url: URL) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let safe: [UTType] = [.image, .pdf, .audiovisualContent, .plainText, .rtf, .spreadsheet, .presentation]
        let risky: [UTType] = [.executable, .script, .application, .applicationBundle, .package, .shellScript]
        if let type, safe.contains(where: type.conforms(to:)), !risky.contains(where: type.conforms(to:)) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Watching for changes

    private func watch(_ folder: URL) {
        let path = canonicalPath(folder)
        guard watcher?.paths != [path] else { return }
        watcher?.stop()
        watcher = FileWatcher(paths: [path]) { [weak self] changed in
            Task { @MainActor in self?.filesChanged(changed) }
        }
        watcher?.start()
    }

    private func filesChanged(_ paths: [String]) {
        if let watchedFilePath, paths.contains(watchedFilePath) {
            documentPane.fileDidChangeOnDisk()
        }
        // FSEvents reports resolved paths (/private/tmp/...); the sidebar uses the
        // folder's path as opened (/tmp/...), so translate before comparing.
        guard let root = rootFolder, let watched = watcher?.paths.first else { return }
        let rootPath = root.path(percentEncoded: false).trimmingSuffix("/")
        sidebar.filesChanged(paths.compactMap { path in
            path.hasPrefix(watched) ? rootPath + path.dropFirst(watched.count) : nil
        })
    }

    // MARK: Unsaved edits

    /// Asks to save unsaved edits. Returns false if the user cancels.
    private func confirmDiscardingEdits() -> Bool {
        guard documentPane.hasUnsavedEdits, let file = documentPane.fileURL else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(file.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return documentPane.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func confirmQuit() -> Bool {
        guard confirmDiscardingEdits() else { return false }
        if chatPanel.isWorking {
            let alert = NSAlert()
            alert.messageText = "Quit while Claude is working on your request?"
            alert.informativeText = "Quitting stops it. Changes Claude already made stay in the document."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        guard terminalPanel.isBusy else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit while a program is running in the terminal?"
        alert.informativeText = "Quitting ends it, including any Claude Code session."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Closing the window only hides it, so the terminal session keeps running.
    /// Click the Dock icon to bring it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: Title and toolbar state

    private func documentStateChanged() {
        updateTitle()
        updateToolbarStates()
        chatPanel.documentChanged()
    }

    private func updateTitle() {
        guard let window else { return }
        if let file = documentPane.fileURL {
            window.title = file.lastPathComponent
            window.subtitle = Self.displayPath(file.deletingLastPathComponent())
            window.representedURL = file
        } else {
            window.title = rootFolder?.lastPathComponent ?? "MD Viewer"
            window.subtitle = rootFolder.map(Self.displayPath) ?? ""
            window.representedURL = rootFolder
        }
        window.isDocumentEdited = documentPane.hasUnsavedEdits
    }

    /// A short, readable folder path: "~/…" and "iCloud Drive/…" instead of the raw paths.
    static func displayPath(_ folder: URL) -> String {
        var path = (folder.path(percentEncoded: false).trimmingSuffix("/") as NSString).abbreviatingWithTildeInPath
        path = path.replacingOccurrences(of: "~/Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive")
        return path
    }

    private func updateToolbarStates() {
        toolbarButtons[.sidebar]?.state = sidebarItem.isCollapsed ? .off : .on
        toolbarButtons[.edit]?.state = documentPane.mode == .split ? .on : .off
        toolbarButtons[.outline]?.state = outlineItem.isCollapsed ? .off : .on
        toolbarButtons[.terminal]?.state = terminalItem.isCollapsed ? .off : .on
        toolbarButtons[.chat]?.state = chatItem.isCollapsed ? .off : .on
        toolbarButtons[.edit]?.isEnabled = documentPane.fileURL != nil
    }

    // MARK: Panels

    private func setSidebarVisible(_ visible: Bool) {
        sidebarItem.animator().isCollapsed = !visible
        Preferences.sidebarVisible = visible
        updateToolbarStates()
    }

    private func setOutlineVisible(_ visible: Bool) {
        outlineItem.animator().isCollapsed = !visible
        Preferences.outlineVisible = visible
        updateToolbarStates()
    }

    private func setChatVisible(_ visible: Bool) {
        if visible, chatPanel.view.frame.width < 300 {
            // First time open: room for a conversation, rather than the minimum width.
            chatItem.isCollapsed = false
            mainSplit.splitView.setPosition(mainSplit.splitView.bounds.width - 340, ofDividerAt: mainSplit.splitViewItems.count - 2)
        }
        chatItem.animator().isCollapsed = !visible
        Preferences.chatVisible = visible
        updateToolbarStates()
        if visible {
            chatPanel.focus()
        } else if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: chatPanel.view) {
            window.makeFirstResponder(documentPane.view)
        }
    }

    /// Ends the chat's Claude Code session (the app is quitting).
    func endChat() {
        chatPanel.endSession()
    }

    /// For the automation hook.
    var chat: ChatPanelController { chatPanel }

    private func setTerminalVisible(_ visible: Bool) {
        if visible { terminalPanel.ensureShell(in: terminalFolder) }
        if visible, terminalPanel.view.frame.height < 200 {
            // First time open: give the terminal a third of the height, rather than its minimum.
            terminalItem.isCollapsed = false
            let height = centerSplit.splitView.bounds.height
            centerSplit.splitView.setPosition(height - min(max(height / 3, 220), 360), ofDividerAt: 0)
        }
        terminalItem.animator().isCollapsed = !visible
        Preferences.terminalVisible = visible
        updateToolbarStates()
        if visible {
            terminalPanel.focus()
        } else if let window, window.firstResponder === terminalPanel.terminal {
            window.makeFirstResponder(documentPane.view)
        }
    }

    private var hasRestoredTerminal = false

    private func showTerminalIfRemembered() {
        guard !hasRestoredTerminal else { return }
        hasRestoredTerminal = true
        if Preferences.terminalVisible { setTerminalVisible(true) }
    }

    /// Where a new shell starts: the folder open in the sidebar (usually the
    /// project root, where CLAUDE.md and git live), else the document's folder.
    private var terminalFolder: URL {
        rootFolder ?? currentFolder ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: Menu actions

    @objc func saveDocument(_ sender: Any?) { documentPane.save() }
    @objc func reloadFromDisk(_ sender: Any?) { documentPane.reloadFromDisk() }
    @objc func exportPDF(_ sender: Any?) { documentPane.exportPDF() }
    func exportPDF(to destination: URL) { documentPane.exportPDF(to: destination) }
    @objc func printDocument(_ sender: Any?) { documentPane.printDocument() }

    @objc func revealInFinder(_ sender: Any?) {
        if let url = documentPane.fileURL ?? rootFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func showPreview(_ sender: Any?) { documentPane.setMode(.preview) }
    @objc func showSource(_ sender: Any?) { documentPane.setMode(.source) }
    @objc func showSplit(_ sender: Any?) { documentPane.setMode(.split) }
    @objc func toggleSourceView(_ sender: Any?) { documentPane.setMode(documentPane.mode == .preview ? .source : .preview) }
    @objc func toggleEditMode(_ sender: Any?) { documentPane.setMode(documentPane.mode == .split ? .preview : .split) }

    @objc func toggleSidebarPanel(_ sender: Any?) { setSidebarVisible(sidebarItem.isCollapsed) }
    @objc func toggleOutline(_ sender: Any?) { setOutlineVisible(outlineItem.isCollapsed) }
    @objc func toggleTerminal(_ sender: Any?) { setTerminalVisible(terminalItem.isCollapsed) }
    @objc func toggleChat(_ sender: Any?) { setChatVisible(chatItem.isCollapsed) }

    @objc func zoomIn(_ sender: Any?) { setZoom(Preferences.zoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Preferences.zoom - 0.1) }
    @objc func resetZoom(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: Double) {
        let zoom = min(max((zoom * 10).rounded() / 10, 0.5), 3)
        Preferences.zoom = zoom
        documentPane.setZoom(zoom)
    }

    @objc func toggleTrust(_ sender: Any?) { documentPane.toggleTrust() }

    @objc func trustCurrentFolder(_ sender: Any?) {
        guard let folder = rootFolder else { return }
        TrustPrompt.confirmTrusting(folder, in: window) { Preferences.setFolderTrusted(true, folder) }
    }

    @objc func performFindAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        let action = NSTextFinder.Action(rawValue: tag) ?? .showFindInterface
        // The terminal has its own find bar.
        if let terminal = terminalPanel.terminal, window?.firstResponder === terminal {
            terminal.performTextFinderAction(sender)
            return
        }
        documentPane.performFind(action, sender: sender, editorFocused: documentPane.isEditorFocused(window?.firstResponder))
    }

    @objc func startClaude(_ sender: Any?) {
        if terminalItem.isCollapsed { setTerminalVisible(true) }
        terminalPanel.startClaude()
    }

    @objc func sendFilePathToTerminal(_ sender: Any?) {
        guard let file = documentPane.fileURL else { return }
        if terminalItem.isCollapsed { setTerminalVisible(true) }
        terminalPanel.paste(terminalPanel.reference(to: file))
    }

    @objc func sendSelectionToTerminal(_ sender: Any?) {
        let editorFocused = documentPane.isEditorFocused(window?.firstResponder)
        Task {
            guard let text = await documentPane.selectedText(editorFocused: editorFocused) else { return NSSound.beep() }
            if terminalItem.isCollapsed { setTerminalVisible(true) }
            terminalPanel.paste(text)
        }
    }

    @objc func newShellHere(_ sender: Any?) {
        if terminalPanel.isBusy {
            let alert = NSAlert()
            alert.messageText = "End the program running in the terminal?"
            alert.informativeText = "A new shell replaces the current one, including any Claude Code session."
            alert.addButton(withTitle: "New Shell")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        terminalPanel.startShell(in: terminalFolder)
        setTerminalVisible(true)
    }

    @objc func toggleAutoStartClaude(_ sender: Any?) {
        Preferences.autoStartClaude.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasDocument = documentPane.fileURL != nil
        switch item.action {
        case #selector(saveDocument(_:)):
            return hasDocument && documentPane.hasUnsavedEdits
        case #selector(reloadFromDisk(_:)), #selector(exportPDF(_:)), #selector(printDocument(_:)),
             #selector(sendFilePathToTerminal(_:)), #selector(sendSelectionToTerminal(_:)), #selector(toggleSourceView(_:)):
            return hasDocument
        case #selector(revealInFinder(_:)):
            return hasDocument || rootFolder != nil
        case #selector(showPreview(_:)):
            item.state = documentPane.mode == .preview ? .on : .off
            return hasDocument
        case #selector(showSource(_:)):
            item.state = documentPane.mode == .source ? .on : .off
            return hasDocument
        case #selector(showSplit(_:)):
            item.state = documentPane.mode == .split ? .on : .off
            return hasDocument
        case #selector(toggleSidebarPanel(_:)):
            item.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
        case #selector(toggleOutline(_:)):
            item.title = outlineItem.isCollapsed ? "Show Outline" : "Hide Outline"
        case #selector(toggleTerminal(_:)):
            item.title = terminalItem.isCollapsed ? "Show Terminal" : "Hide Terminal"
        case #selector(toggleChat(_:)):
            item.title = chatItem.isCollapsed ? "Show Chat" : "Hide Chat"
        case #selector(toggleTrust(_:)):
            item.state = documentPane.isTrusted ? .on : .off
            // A file trusted through its folder is changed from Trusted Folders instead.
            return documentPane.kind == .html && !documentPane.isTrustedByFolder
        case #selector(trustCurrentFolder(_:)):
            guard let folder = rootFolder else { return false }
            item.title = "Trust “\(folder.lastPathComponent)”…"
            return !Preferences.isFolderTrusted(folder)
        case #selector(toggleAutoStartClaude(_:)):
            item.state = Preferences.autoStartClaude ? .on : .off
        case #selector(performFindAction(_:)):
            return hasDocument || window?.firstResponder === terminalPanel.terminal
        default:
            break
        }
        return true
    }

    // MARK: Toolbar

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        updateToolbarStates()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .sidebarTrackingSeparator, .flexibleSpace, .edit, .outline, .terminal, .chat]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let spec: (symbol: String, label: String, action: Selector)
        switch identifier {
        case .sidebar: spec = ("sidebar.left", "Sidebar (⌃⌘S)", #selector(toggleSidebarPanel(_:)))
        case .edit: spec = ("pencil", "Edit with Live Preview (⌘3)", #selector(toggleEditMode(_:)))
        case .outline: spec = ("list.bullet.indent", "Outline (⌃⌘O)", #selector(toggleOutline(_:)))
        case .terminal: spec = ("terminal", "Terminal (⌃`)", #selector(toggleTerminal(_:)))
        case .chat: spec = ("text.bubble", "Chat (⌃⌘C)", #selector(toggleChat(_:)))
        default: return nil
        }
        let button = NSButton(image: NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)!, target: self, action: spec.action)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .toolbar
        button.toolTip = spec.label
        if identifier == .chat { button.image = ClaudeSymbol.image(size: 17) }
        toolbarButtons[identifier] = button
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = spec.label
        item.toolTip = spec.label
        return item
    }

    // MARK: Alerts

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - Chat

extension MainWindowController: ChatHost {
    var chatDocument: URL? { documentPane.fileURL }

    var chatFolder: URL { terminalFolder }

    func saveDocumentForChat() -> Bool {
        !documentPane.hasUnsavedEdits || documentPane.save()
    }

    func chatSelection() async -> String? {
        await documentPane.selectionForChat()
    }

    func openChatLink(_ action: LinkAction) {
        follow(action)
    }

    func runInTerminal(_ command: String) {
        let justStarted = !terminalPanel.isShellRunning
        // Don't let "Start Claude Code Automatically" type into the command.
        if justStarted { terminalPanel.startShell(in: terminalFolder, startingClaude: false) }
        setTerminalVisible(true)
        terminalPanel.run(command, justStarted: justStarted)
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("sidebar")
    static let edit = Self("edit")
    static let outline = Self("outline")
    static let terminal = Self("terminal")
    static let chat = Self("chat")
}
