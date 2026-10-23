import AppKit
import MDViewerCore
import WebKit

/// The chat's transcript: a display-only page (web/chat.html) that renders the
/// items the app sends it. Like the document preview, it has no script
/// message handlers, so nothing in a reply can call the app; links are handled
/// natively.
@MainActor
final class ChatTranscriptView: NSObject, WKNavigationDelegate {
    static let pageURL = URL(string: "mdv-app://app/chat.html")!

    let webView: DocumentWebView
    var onLink: ((LinkAction) -> Void)?
    /// The chat's folder: relative links in replies resolve against it.
    var folder: URL?

    private var pageLoaded = false
    private var waiting: [() -> Void] = []
    /// Everything shown, in order, to put back if the page's process crashes.
    private var shown: [ChatItem] = []
    private var status: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppResourceSchemeHandler(root: AppResources.webRoot), forURLScheme: AppResourceSchemeHandler.scheme)
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileURL.scheme)
        config.websiteDataStore = .nonPersistent()
        webView = DocumentWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.isInspectable = ProcessInfo.processInfo.environment["MDV_INSPECTABLE"] == "1"
        webView.setAccessibilityLabel("Chat transcript")
        webView.load(URLRequest(url: Self.pageURL))
    }

    /// Adds new items and redraws changed ones.
    func upsert(_ items: [ChatItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            if let index = shown.firstIndex(where: { $0.id == item.id }) { shown[index] = item } else { shown.append(item) }
        }
        call("window.chat.upsert(items, options)", ["items": Self.plist(items), "options": options])
    }

    func reset() {
        shown.removeAll()
        status = nil
        call("window.chat.reset()", [:])
    }

    /// A short line under the conversation ("Thinking"), or nil to hide it.
    func setStatus(_ text: String?) {
        guard text != status else { return }
        status = text
        call("window.chat.setStatus(text)", ["text": text ?? NSNull()])
    }

    private var options: [String: Any] {
        guard let folder else { return [:] }
        return ["baseDir": URL(fileURLWithPath: folder.path(percentEncoded: false), isDirectory: true).absoluteString]
    }

    private func call(_ script: String, _ arguments: [String: Any]) {
        let run: () -> Void = { [webView] in
            _ = Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
                } catch {
                    NSLog("MD Viewer: chat page call failed: \(error)")
                }
            }
        }
        if pageLoaded { run() } else { waiting.append(run) }
    }

    /// Items as the property-list values JavaScript calls accept.
    private static func plist(_ items: [ChatItem]) -> [Any] {
        guard let data = try? JSONEncoder().encode(items),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return objects
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        let calls = waiting
        waiting.removeAll()
        calls.forEach { $0() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload and show everything again.
        pageLoaded = false
        waiting.removeAll()
        let items = shown, text = status
        shown.removeAll()
        status = nil
        webView.load(URLRequest(url: Self.pageURL))
        upsert(items)
        setStatus(text)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == AppResourceSchemeHandler.scheme, url.path(percentEncoded: false) == Self.pageURL.path(percentEncoded: false) {
            return decisionHandler(.allow)
        }
        // Links in replies open natively; the page itself never navigates away.
        if navigationAction.navigationType == .linkActivated {
            onLink?(LinkRouter.action(for: url))
        }
        decisionHandler(.cancel)
    }
}
