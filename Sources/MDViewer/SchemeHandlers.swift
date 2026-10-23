import Foundation
import MDViewerCore
import WebKit

/// Serves the preview page, its scripts and styles from the app's resources,
/// under `mdv-app://app/`.
@MainActor
final class AppResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdv-app"
    static let pageURL = URL(string: "mdv-app://app/index.html")!

    private let rootPath: String

    init(root: URL) {
        rootPath = root.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let relative = url.path(percentEncoded: false)
        let file = URL(fileURLWithPath: rootPath + "/" + relative).standardizedFileURL
        // Refuse anything outside the web folder (for example "../").
        guard file.path(percentEncoded: false).hasPrefix(rootPath + "/"),
              let type = MediaTypes.webAssetType(for: file),
              let data = try? Data(contentsOf: file)
        else { return task.respond(url: url, status: 404) }
        task.respond(url: url, status: 200, type: type, data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Serves local images, audio and video to the markdown preview under
/// `mdv-file://local/<path>`. Only media types are served, so a document cannot
/// pull other files (keys, configs) into the page.
@MainActor
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let file = LocalFileURL.fileURL(from: url),
              let type = MediaTypes.embeddableType(for: file),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return task.respondNotFound() }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // Video and audio are read in ranges; images are read whole.
        if let header = task.request.value(forHTTPHeaderField: "Range"),
           let range = ByteRange(header: header, fileSize: size) {
            try? handle.seek(toOffset: range.start)
            let data = (try? handle.read(upToCount: Int(range.length))) ?? Data()
            task.respond(url: url, status: 206, type: type, data: data, headers: [
                "Content-Range": "bytes \(range.start)-\(range.start + UInt64(data.count) - 1)/\(size)",
                "Accept-Ranges": "bytes",
            ])
        } else {
            try? handle.seek(toOffset: 0)
            let data = (try? handle.readToEnd()) ?? Data()
            task.respond(url: url, status: 200, type: type, data: data, headers: ["Accept-Ranges": "bytes"])
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A parsed `Range: bytes=start-end` request header.
private struct ByteRange {
    let start: UInt64
    let length: UInt64

    init?(header: String, fileSize: UInt64) {
        guard fileSize > 0, header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = UInt64(bounds[0]), start < fileSize else { return nil }
        let end = min(UInt64(bounds[1]) ?? (fileSize - 1), fileSize - 1)
        guard end >= start else { return nil }
        self.start = start
        self.length = end - start + 1
    }
}

private extension WKURLSchemeTask {
    func respond(url: URL, status: Int, type: String = "text/plain", data: Data = Data(), headers: [String: String] = [:]) {
        var fields = headers
        fields["Content-Type"] = type
        fields["Content-Length"] = String(data.count)
        fields["Cache-Control"] = "no-cache"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        didReceive(response)
        didReceive(data)
        didFinish()
    }

    func respondNotFound() {
        guard let url = request.url else { return didFailWithError(URLError(.badURL)) }
        respond(url: url, status: 404)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.count > 1, result.hasSuffix(suffix) { result.removeLast(suffix.count) }
        return result
    }
}
