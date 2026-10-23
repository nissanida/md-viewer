import Foundation
import UniformTypeIdentifiers

/// The kinds of files the app can display.
public enum DocumentKind: Sendable, Equatable {
    case markdown
    case html

    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "mdx",
    ]
    public static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    public init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.htmlExtensions.contains(ext) {
            self = .html
        } else {
            return nil
        }
    }
}

extension DocumentKind {
    /// The file types this Mac uses for this kind's extensions. Other apps may
    /// declare their own type for an extension (Typora does for .mdx), so the
    /// list comes from the system rather than a fixed set of identifiers.
    public var fileTypes: [UTType] {
        let extensions = self == .markdown ? Self.markdownExtensions : Self.htmlExtensions
        var seen = Set<String>()
        return extensions.sorted()
            .compactMap { UTType(filenameExtension: $0) }
            .filter { !$0.isDynamic && seen.insert($0.identifier).inserted }
    }
}
