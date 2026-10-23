import Foundation

/// What to do when the user clicks a link in a preview.
public enum LinkAction: Equatable, Sendable {
    /// A markdown or HTML file: open it in the app, optionally scrolled to an anchor.
    case openDocument(URL, fragment: String?)
    /// Any other local file or folder: hand it to its default app (Finder, Preview, ...).
    case openFile(URL)
    /// A web page, mail address and so on: open it in the default browser or app.
    case openExternal(URL)
    /// Anything else (javascript:, data:, unknown schemes) is ignored.
    case ignore
}

public enum LinkRouter {
    static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel", "ftp"]

    public static func action(for url: URL) -> LinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        if externalSchemes.contains(scheme) { return .openExternal(url) }

        let target: URL?
        switch scheme {
        case "file": target = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
        case LocalFileURL.scheme: target = LocalFileURL.fileURL(from: url)
        default: target = nil
        }
        guard let target else { return .ignore }

        if DocumentKind(url: target) != nil {
            let fragment = url.fragment(percentEncoded: false)
            return .openDocument(target, fragment: fragment?.isEmpty == false ? fragment : nil)
        }
        return .openFile(target)
    }
}
