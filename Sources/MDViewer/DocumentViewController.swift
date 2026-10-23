import AppKit
import MDViewerCore
import UniformTypeIdentifiers
import WebKit

/// Shows one document as a rendered preview, as raw source, or both side by
/// side. Owns the document's text, its unsaved edits, and reloading it when it
/// changes on disk (for example, when Claude Code edits it).
@MainActor
final class DocumentViewController: NSViewController {
    var onStateChange: (() -> Void)?
    var onOutline: (([OutlineItem]) -> Void)?
    var onLink: ((LinkAction) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    private(set) var fileURL: URL?
    private(set) var kind: DocumentKind?
    private(set) var mode: ViewMode = Preferences.viewMode
    private(set) var hasUnsavedEdits = false
    /// The open folder: links starting with "/" resolve against it, and HTML files may read from it.
    var rootFolder: URL?

    /// The content last read from or written to disk, to tell real changes from our own saves.
    private var lastLoadedText = ""
    private var encoding: String.Encoding = .utf8
    private var hasByteOrderMark = false

    private let markdown = MarkdownPreview()
    /// Created the first time an HTML file is opened.
    private var htmlPreview: HTMLPreview?
    private var html: HTMLPreview {
        if let htmlPreview { return htmlPreview }
        let preview = makeHTMLPreview()
        htmlPreview = preview
        return preview
    }
    private let editor = SourceEditor()
    private let emptyState = EmptyStateView()
    private let findBar = FindBar()
    /// Banners and the find bar, above the document. Hidden views take no space.
    private let topStack = NSStackView()
    private var banner: BannerView?
    private let content = NSView()
    private let split = NSSplitView()

    private enum Notice { case none, changedOnDisk(String), deleted }
    /// A suggestion from the window (the default-app offer), shown when no notice about the file is.
    var tip: BannerView? {
        didSet { updateBanner() }
    }
    private var notice = Notice.none
    private var renderTask: Task<Void, Never>?
    private var pendingEditRender: DispatchWorkItem?

    // MARK: Setup

    override func loadView() {
        let root = NSView()
        findBar.isHidden = true
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 0
        topStack.detachesHiddenViews = true
        addToTop(findBar, at: 0)
        for view in [topStack, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            topStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "EditSplit"

        markdown.onLink = { [weak self] in self?.onLink?($0) }
        markdown.webView.onDropFiles = { [weak self] in self?.onDropFiles?($0) }
        editor.textView.onDropFiles = { [weak self] in self?.onDropFiles?($0) }
        emptyState.onDropFiles = { [weak self] in self?.onDropFiles?($0) }
        editor.onChange = { [weak self] in self?.editorDidChange() }
        findBar.onSearch = { [weak self] text, backwards in self?.findInPreview(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        view = root
        setZoom(Preferences.zoom)
        layoutContent(moveFocus: false)

        // Trust can change from the banner or the View menu: reload the page either way.
        NotificationCenter.default.addObserver(forName: Preferences.trustDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trustDidChange() }
        }
    }

    /// Whether keyboard focus is in the document (or nowhere). Opening a file from
    /// the sidebar or the terminal leaves focus there, so arrow keys keep working.
    private var documentHasFocus: Bool {
        guard let window = view.window else { return true }
        guard let responder = window.firstResponder as? NSView else { return true }
        return responder.isDescendant(of: view)
    }

    private func addToTop(_ view: NSView, at index: Int) {
        topStack.insertArrangedSubview(view, at: index)
        view.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
    }

    private func makeHTMLPreview() -> HTMLPreview {
        let preview = HTMLPreview()
        preview.onLink = { [weak self] in self?.onLink?($0) }
        preview.onLoad = { [weak self] in self?.htmlDidLoad() }
        preview.webView.onDropFiles = { [weak self] in self?.onDropFiles?($0) }
        preview.webView.pageZoom = Preferences.zoom
        return preview
    }

    // MARK: Opening and saving

    /// Opens a document. Returns false (after telling the user) if it can't be read.
    @discardableResult
    func open(_ url: URL, fragment: String? = nil) -> Bool {
        let url = url.standardizedFileURL
        if url == fileURL {
            if let fragment { scrollTo(anchor: fragment) }
            return true
        }
        guard let kind = DocumentKind(url: url) else { return false }
        guard let loaded = Self.read(url) else {
            showError("“\(url.lastPathComponent)” couldn’t be opened.", detail: "The file may have been moved, or you may not have permission to read it.")
            return false
        }
        fileURL = url
        self.kind = kind
        encoding = loaded.encoding
        hasByteOrderMark = loaded.hasByteOrderMark
        lastLoadedText = loaded.text
        hasUnsavedEdits = false
        notice = .none
        editor.setText(loaded.text, keepPosition: false)
        hideFindBar()
        layoutContent(moveFocus: documentHasFocus)
        refreshPreview(preserveScroll: false, fragment: fragment)
        updateBanner()
        onStateChange?()
        return true
    }

    /// Clears the view (the open file was closed or its folder changed).
    func closeDocument() {
        emptyState.folderIsOpen = rootFolder != nil
        fileURL = nil
        kind = nil
        hasUnsavedEdits = false
        notice = .none
        editor.setText("", keepPosition: false)
        layoutContent(moveFocus: false)
        updateBanner()
        onOutline?([])
        onStateChange?()
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return false }
        let text = editor.text
        guard let data = ((hasByteOrderMark ? "\u{FEFF}" : "") + text).data(using: encoding) else {
            showError("“\(url.lastPathComponent)” couldn’t be saved.", detail: "Some characters can't be stored in the file's text encoding.")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError("“\(url.lastPathComponent)” couldn’t be saved.", detail: error.localizedDescription)
            return false
        }
        lastLoadedText = text
        hasUnsavedEdits = false
        if case .changedOnDisk = notice { notice = .none }
        if case .deleted = notice { notice = .none }
        if kind == .html { html.reload() }
        updateBanner()
        onStateChange?()
        return true
    }

    /// Reads the file again, dropping unsaved edits.
    func reloadFromDisk() {
        guard let url = fileURL, let loaded = Self.read(url) else { return }
        apply(diskText: loaded.text)
    }

    /// Called when the file may have changed on disk.
    func fileDidChangeOnDisk() {
        guard let url = fileURL else { return }
        let diskText = Self.read(url)?.text
        switch ReloadPolicy.decide(diskContent: diskText, lastLoaded: lastLoadedText, hasUnsavedEdits: hasUnsavedEdits) {
        case .ignore:
            if case .deleted = notice { notice = .none; updateBanner() }
        case .reload(let text):
            apply(diskText: text)
        case .conflict(let text):
            notice = .changedOnDisk(text)
            updateBanner()
        case .deleted:
            notice = .deleted
            updateBanner()
        }
    }

    private func apply(diskText text: String) {
        lastLoadedText = text
        hasUnsavedEdits = false
        notice = .none
        editor.setText(text, keepPosition: true)
        refreshPreview(preserveScroll: true)
        updateBanner()
        onStateChange?()
    }

    // MARK: Modes

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        Preferences.viewMode = newMode
        hideFindBar()
        layoutContent(moveFocus: true)
        // The preview always follows the editor's text, including unsaved edits.
        if kind == .markdown { refreshPreview(preserveScroll: true) }
        onStateChange?()
    }

    private func layoutContent(moveFocus: Bool) {
        content.subviews.forEach { $0.removeFromSuperview() }
        split.subviews.forEach { $0.removeFromSuperview() }

        guard let kind else { return fill(content, with: emptyState) }
        let preview: NSView = kind == .markdown ? markdown.webView : html.webView
        let focus: NSView
        switch mode {
        case .preview:
            fill(content, with: preview)
            focus = preview
        case .source:
            fill(content, with: editor.scrollView)
            focus = editor.textView
        case .split:
            split.addArrangedSubview(editor.scrollView)
            split.addArrangedSubview(preview)
            fill(content, with: split)
            split.adjustSubviews()
            if split.subviews.first?.frame.width ?? 0 < 50 {
                split.setPosition(content.bounds.width / 2, ofDividerAt: 0)
            }
            focus = editor.textView
        }
        if moveFocus { view.window?.makeFirstResponder(focus) }
    }

    private func fill(_ container: NSView, with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Preview

    private func refreshPreview(preserveScroll: Bool, fragment: String? = nil) {
        guard let url = fileURL, let kind else { return }
        switch kind {
        case .markdown:
            renderTask?.cancel()
            let text = editor.text
            renderTask = Task { [weak self] in
                guard let self else { return }
                let outline = await markdown.render(text, file: url, root: rootFolder, preserveScroll: preserveScroll, fragment: fragment)
                if !Task.isCancelled { onOutline?(outline) }
            }
        case .html:
            if preserveScroll, html.file == url {
                html.reload()
            } else {
                pendingHTMLAnchor = fragment
                Task { await html.load(url, readAccess: htmlReadAccess(for: url), trusted: Preferences.isTrusted(url)) }
            }
        }
    }

    private var pendingHTMLAnchor: String?

    private func htmlDidLoad() {
        if let anchor = pendingHTMLAnchor {
            html.scrollTo(anchor: anchor)
            pendingHTMLAnchor = nil
        }
        Task { onOutline?(await html.outline()) }
    }

    /// HTML files may load their own CSS, scripts and images from their folder,
    /// or from the whole open folder when they are inside it.
    private func htmlReadAccess(for file: URL) -> URL {
        if let root = rootFolder, file.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false).trimmingSuffix("/") + "/") {
            return root
        }
        return file.deletingLastPathComponent()
    }

    private func editorDidChange() {
        hasUnsavedEdits = editor.text != lastLoadedText
        onStateChange?()
        guard kind == .markdown else { return }
        // Live preview while typing, a moment after the last keystroke.
        pendingEditRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview(preserveScroll: true) }
        pendingEditRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func scrollTo(anchor id: String) {
        if kind == .html { html.scrollTo(anchor: id) } else { markdown.scrollTo(anchor: id) }
    }

    // MARK: HTML trust

    var isTrusted: Bool { fileURL.map(Preferences.isTrusted) ?? false }

    /// Whether the open file is trusted through a trusted folder (not on its own).
    var isTrustedByFolder: Bool { fileURL.flatMap(Preferences.trustingFolder) != nil }

    /// Trusts or stops trusting the open HTML file on its own.
    func toggleTrust() {
        guard let url = fileURL, kind == .html else { return }
        Preferences.setTrusted(!Preferences.isFileTrusted(url), for: url)
    }

    /// Trusts every HTML file in the folder open in the sidebar, after asking.
    func trustRootFolder() {
        guard let folder = rootFolder else { return }
        TrustPrompt.confirmTrusting(folder, in: view.window) {
            Preferences.setFolderTrusted(true, folder)
        }
    }

    private func trustDidChange() {
        guard let url = fileURL, kind == .html else { return }
        Task { await html.load(url, readAccess: htmlReadAccess(for: url), trusted: Preferences.isTrusted(url)) }
        updateBanner()
        onStateChange?()
    }

    // MARK: Notices

    private func updateBanner() {
        banner?.removeFromSuperview()
        let banner: BannerView?
        switch notice {
        case .changedOnDisk(let text):
            banner = BannerView(symbol: "arrow.triangle.2.circlepath", message: "This file changed on disk while you have unsaved edits.", tone: .warning, actions: [
                ("Use Version on Disk", { [weak self] in self?.apply(diskText: text) }),
                ("Keep My Edits", { [weak self] in
                    // Saving will now replace the version on disk.
                    self?.lastLoadedText = text
                    self?.notice = .none
                    self?.updateBanner()
                }),
            ])
        case .deleted:
            banner = BannerView(symbol: "trash", message: "This file was deleted or moved. Save to create it again.", tone: .warning)
        case .none:
            banner = htmlBanner() ?? tip
        }
        if let banner { addToTop(banner, at: 0) }
        self.banner = banner
    }

    /// Explains what is blocked in an untrusted HTML file, with the ways to allow it.
    private func htmlBanner() -> BannerView? {
        guard kind == .html, let url = fileURL else { return nil }
        let scan = HTMLContentScan(html: lastLoadedText)
        guard scan.hasScripts || scan.hasRemoteResources else { return nil }

        if let folder = Preferences.trustingFolder(for: url) {
            return BannerView(symbol: "checkmark.shield",
                              message: "You trust the folder “\(folder.lastPathComponent)”: scripts in its HTML files run and can load content from the internet.",
                              actions: [("Stop Trusting Folder", { Preferences.setFolderTrusted(false, folder) })])
        }
        if Preferences.isFileTrusted(url) {
            return BannerView(symbol: "checkmark.shield", message: "You trust this file: its scripts run and it can load content from the internet.",
                              actions: [("Stop Trusting", { [weak self] in self?.toggleTrust() })])
        }
        let blocked = switch (scan.hasScripts, scan.hasRemoteResources) {
        case (true, true): "Scripts and content from the internet are blocked in this file."
        case (true, false): "Scripts are turned off in this file."
        default: "Content from the internet is blocked in this file."
        }
        var actions: [(String, () -> Void)] = [("Trust This File", { [weak self] in self?.toggleTrust() })]
        if rootFolder != nil {
            actions.append(("Trust Folder…", { [weak self] in self?.trustRootFolder() }))
        }
        return BannerView(symbol: "shield", message: blocked, actions: actions)
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Find

    func performFind(_ action: NSTextFinder.Action, sender: Any?, editorFocused: Bool) {
        guard kind != nil else { return }
        if mode == .source || (mode == .split && editorFocused) {
            if action == .showFindInterface { view.window?.makeFirstResponder(editor.textView) }
            editor.textView.performTextFinderAction(sender)
            return
        }
        switch action {
        case .showFindInterface:
            showFindBar()
        case .nextMatch:
            findBar.isHidden ? showFindBar() : findBar.findNext()
        case .previousMatch:
            findBar.isHidden ? showFindBar() : findBar.findPrevious()
        case .setSearchString:
            Task {
                guard let text = await previewSelection() else { return }
                findBar.field.stringValue = text
                showFindBar()
            }
        case .hideFindInterface:
            hideFindBar()
        default:
            break
        }
    }

    private func showFindBar() {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
    }

    private func hideFindBar() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findBar.show(found: nil)
        if mode != .source { view.window?.makeFirstResponder(activeWebView) }
    }

    private func findInPreview(_ text: String, backwards: Bool) {
        guard let webView = activeWebView else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        Task {
            let found = (try? await webView.find(text, configuration: config))?.matchFound ?? false
            findBar.show(found: found)
        }
    }

    // MARK: Text for the terminal

    /// The selected text: in the editor when it has focus, otherwise in the preview.
    func selectedText(editorFocused: Bool) async -> String? {
        if editorFocused || mode == .source, let text = editor.selectedText() { return text }
        return await previewSelection()
    }

    private func previewSelection() async -> String? {
        switch kind {
        case .markdown: await markdown.selectedText()
        case .html: await html.selectedText()
        case nil: nil
        }
    }

    func isEditorFocused(_ responder: NSResponder?) -> Bool {
        responder === editor.textView
    }

    // MARK: Zoom, print, PDF

    func setZoom(_ zoom: Double) {
        markdown.webView.pageZoom = zoom
        htmlPreview?.webView.pageZoom = zoom
        editor.setZoom(zoom)
    }

    private var activeWebView: DocumentWebView? {
        switch kind {
        case .markdown: markdown.webView
        case .html: html.webView
        case nil: nil
        }
    }

    func printDocument() {
        guard let window = view.window else { return }
        if mode == .source { setMode(.preview) }
        activeWebView?.runPrint(in: window)
    }

    func exportPDF() {
        guard let window = view.window, let url = fileURL else { return }
        if mode == .source { setMode(.preview) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            // Let the sheet finish closing before the print operation starts.
            DispatchQueue.main.async { self?.exportPDF(to: destination) }
        }
    }

    func exportPDF(to destination: URL) {
        guard let window = view.window else { return }
        if mode == .source { setMode(.preview) }
        activeWebView?.runPrint(in: window, savingTo: destination)
    }

    // MARK: Reading files

    private static func read(_ url: URL) -> (text: String, encoding: String.Encoding, hasByteOrderMark: Bool)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text: String
        var encoding = String.Encoding.utf8
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            var detected = String.Encoding.utf8
            if let decoded = try? String(contentsOf: url, usedEncoding: &detected) {
                text = decoded
                encoding = detected
            } else if let decoded = String(data: data, encoding: .windowsCP1252) {
                text = decoded
                encoding = .windowsCP1252
            } else {
                return nil
            }
        }
        let hasByteOrderMark = text.hasPrefix("\u{FEFF}")
        if hasByteOrderMark { text.removeFirst() }
        return (text, encoding, hasByteOrderMark)
    }
}
