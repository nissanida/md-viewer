import AppKit
import MDViewerCore
import WebKit

/// A heading in the current document, for the outline panel.
struct OutlineItem: Equatable {
    let level: Int
    let text: String
    let id: String

    /// Reads the `[{level, text, id}]` array returned by the page scripts.
    static func list(from value: Any?) -> [OutlineItem] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let level = entry["level"] as? Int, let text = entry["text"] as? String,
                  let id = entry["id"] as? String else { return nil }
            return OutlineItem(level: level, text: text, id: id)
        }
    }
}

/// Where the app's web assets live: inside the app bundle, or the repository's
/// web/ folder when running from source with `swift run`.
enum AppResources {
    static let webRoot: URL = {
        let bundled = Bundle.main.resourceURL?.appending(path: "web")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appending(path: "index.html").path(percentEncoded: false)) {
            return bundled
        }
        #if DEBUG
        return URL(fileURLWithPath: #filePath) // Sources/MDViewer/Previews.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "web")
        #else
        // #filePath would put the builder's folder (and user name) into the app.
        return bundled ?? Bundle.main.bundleURL.appending(path: "Contents/Resources/web")
        #endif
    }()
}

/// A web view with a context menu trimmed for reading, and file drops that open
/// in the app instead of navigating the view.
final class DocumentWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let unwanted = [
            "Reload", "OpenLinkInNewWindow", "DownloadLinkedFile", "GoBack", "GoForward",
            "OpenImageInNewWindow", "DownloadImage", "OpenFrameInNewWindow", "OpenMediaInNewWindow", "DownloadMedia",
        ].map { "WKMenuItemIdentifier" + $0 }
        menu.items.removeAll { unwanted.contains($0.identifier?.rawValue ?? "") }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        super.willOpenMenu(menu, with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(files)
        return true
    }

    /// Prints or saves the page as PDF. WebKit needs the operation run modally
    /// on a window, with the print view given a frame, or the output is blank.
    func runPrint(in window: NSWindow, savingTo destination: URL? = nil) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 40
        info.bottomMargin = 40
        info.leftMargin = 40
        info.rightMargin = 40
        info.isVerticallyCentered = false
        if let destination {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        }
        let operation = printOperation(with: info)
        operation.view?.frame = bounds
        operation.showsPrintPanel = destination == nil
        operation.showsProgressPanel = destination == nil
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

@MainActor
func droppedFiles(_ info: any NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

// MARK: - Markdown

/// Shows rendered markdown. The page (web/index.html) is loaded once; each
/// document is rendered into it by page.js, so switching files is instant.
@MainActor
final class MarkdownPreview: NSObject, WKNavigationDelegate {
    let webView: DocumentWebView
    var onLink: ((LinkAction) -> Void)?

    private var pageLoaded = false
    private var waitingForPage: [CheckedContinuation<Void, Never>] = []
    private var lastRender: (source: String, options: [String: Any])?

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppResourceSchemeHandler(root: AppResources.webRoot), forURLScheme: AppResourceSchemeHandler.scheme)
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileURL.scheme)
        config.websiteDataStore = .nonPersistent()
        webView = DocumentWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.isInspectable = ProcessInfo.processInfo.environment["MDV_INSPECTABLE"] == "1"
        webView.setAccessibilityLabel("Preview")
        webView.load(URLRequest(url: AppResourceSchemeHandler.pageURL))
    }

    /// Renders `markdown` and returns its outline.
    /// - Parameters:
    ///   - file: the document, for resolving relative links and images
    ///   - root: the open folder, for links that start with "/"
    ///   - preserveScroll: keep the reading position (live reload, typing in the editor)
    ///   - fragment: an anchor to scroll to
    @discardableResult
    func render(_ markdown: String, file: URL, root: URL?, preserveScroll: Bool, fragment: String? = nil) async -> [OutlineItem] {
        var options: [String: Any] = [
            "baseDir": file.deletingLastPathComponent().absoluteString,
            "preserveScroll": preserveScroll,
        ]
        if let root { options["rootDir"] = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: true).absoluteString }
        if let fragment { options["fragment"] = fragment }
        lastRender = (markdown, options.merging(["preserveScroll": true]) { $1 })

        await pageReady()
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.mdv.render(source, options)",
                arguments: ["source": markdown, "options": options], contentWorld: .page)
            return OutlineItem.list(from: result)
        } catch {
            NSLog("MD Viewer: render failed: \(error)")
            return []
        }
    }

    func scrollTo(anchor id: String) {
        Task { _ = try? await webView.callAsyncJavaScript("window.mdv.scrollToAnchor(id)", arguments: ["id": id], contentWorld: .page) }
    }

    func selectedText() async -> String? {
        let text = try? await webView.callAsyncJavaScript("return window.mdv.selectionText()", contentWorld: .page) as? String
        return text?.isEmpty == false ? text : nil
    }

    private func pageReady() async {
        if pageLoaded { return }
        await withCheckedContinuation { waitingForPage.append($0) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let reloaded = lastRender != nil && waitingForPage.isEmpty
        pageLoaded = true
        waitingForPage.forEach { $0.resume() }
        waitingForPage.removeAll()
        // The page came back after a crash or reload: show the document again.
        if reloaded, let last = lastRender {
            Task { _ = try? await webView.callAsyncJavaScript(
                "return window.mdv.render(source, options)",
                arguments: ["source": last.source, "options": last.options], contentWorld: .page) }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoaded = false
        webView.load(URLRequest(url: AppResourceSchemeHandler.pageURL))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        // The preview page itself, including jumps to anchors within it.
        if url.scheme == AppResourceSchemeHandler.scheme, url.path(percentEncoded: false) == "/index.html" {
            return decisionHandler(.allow)
        }
        // Every other link is handled natively; the preview never navigates away.
        if navigationAction.navigationType == .linkActivated {
            onLink?(LinkRouter.action(for: url))
        }
        decisionHandler(.cancel)
    }
}

// MARK: - HTML

/// Shows an HTML file in its own web view. By default its scripts are off and
/// requests to the network are blocked; the user can trust a file to allow both.
@MainActor
final class HTMLPreview: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: DocumentWebView
    var onLink: ((LinkAction) -> Void)?
    var onLoad: (() -> Void)?

    private(set) var file: URL?
    private var trusted = false
    private let remoteBlocker = Task { await HTMLPreview.compileRemoteBlocker() }

    override init() {
        let config = WKWebViewConfiguration()
        // Nothing an HTML file stores (cookies, local storage) outlives the app.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = DocumentWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.isInspectable = ProcessInfo.processInfo.environment["MDV_INSPECTABLE"] == "1"
        webView.setAccessibilityLabel("HTML preview")
    }

    /// Loads `file`, letting it read files under `readAccess` (its folder, or the open folder).
    func load(_ file: URL, readAccess: URL, trusted: Bool) async {
        self.file = file.standardizedFileURL
        self.trusted = trusted
        let content = webView.configuration.userContentController
        content.removeAllContentRuleLists()
        if !trusted, let blocker = await remoteBlocker.value {
            content.add(blocker)
        }
        webView.loadFileURL(file, allowingReadAccessTo: readAccess)
    }

    /// Re-reads the file after it changed on disk; WebKit keeps the scroll position.
    func reload() {
        webView.reload()
    }

    func outline() async -> [OutlineItem] {
        // Runs in the app's own script world, so it works with the page's scripts off.
        let script = """
            return Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6')).map((h, i) => {
              if (!h.id) h.id = 'mdv-heading-' + i
              return { level: Number(h.tagName[1]), text: h.textContent.trim().replace(/\\s+/g, ' '), id: h.id }
            })
            """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        return OutlineItem.list(from: result)
    }

    func scrollTo(anchor id: String) {
        Task { _ = try? await webView.callAsyncJavaScript(
            "document.getElementById(id)?.scrollIntoView({ block: 'start' })",
            arguments: ["id": id], contentWorld: .defaultClient) }
    }

    func selectedText() async -> String? {
        let text = try? await webView.callAsyncJavaScript("return String(window.getSelection())", contentWorld: .defaultClient) as? String
        return text?.isEmpty == false ? text : nil
    }

    /// Blocks every request to the network. WebKit enforces this for images,
    /// styles, scripts, fonts, frames and fetches alike.
    private static func compileRemoteBlocker() async -> WKContentRuleList? {
        let rules = """
            [
              {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
              {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
              {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}
            ]
            """
        return try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "MDViewer.BlockRemote", encodedContentRuleList: rules)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoad?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = trusted
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel, preferences) }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let samePage = url.isFileURL && URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL == file
        if isMainFrame, samePage, navigationAction.navigationType != .formSubmitted {
            return decisionHandler(.allow, preferences) // the file itself, a reload, or an anchor in it
        }
        if !isMainFrame, url.isFileURL || url.scheme == "about" || (trusted && ["http", "https"].contains(url.scheme ?? "")) {
            return decisionHandler(.allow, preferences) // frames inside the page
        }
        if navigationAction.navigationType == .linkActivated {
            onLink?(LinkRouter.action(for: url))
        }
        decisionHandler(.cancel, preferences)
    }

    // MARK: WKUIDelegate

    /// Links with target="_blank" and window.open().
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onLink?(LinkRouter.action(for: url)) }
        return nil
    }
}
