import Foundation

/// A quick look at an HTML file to tell the user what is being blocked.
/// This only drives the notice; blocking itself is done by WebKit.
public struct HTMLContentScan: Equatable, Sendable {
    public let hasScripts: Bool
    public let hasRemoteResources: Bool

    public init(html: String) {
        hasScripts = Self.matches(html, #"<script\b|<[^>]+\son[a-z]+\s*=|javascript:"#)
        hasRemoteResources = Self.matches(html, Self.remotePattern)
    }

    // Attributes and CSS that load something, followed by an http(s) or protocol-relative URL.
    private static let remoteURL = #"\s*["']?\s*(?:https?:)?//"#
    private static let remotePattern = [
        #"<(?:img|script|iframe|frame|embed|source|video|audio|track|input)\b[^>]*\s(?:src|srcset|poster)\s*="# + remoteURL,
        #"<link\b[^>]*\shref\s*="# + remoteURL,
        #"<object\b[^>]*\sdata\s*="# + remoteURL,
        #"url\("# + remoteURL,
        #"@import\s+(?:url\()?"# + remoteURL,
    ].joined(separator: "|")

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
