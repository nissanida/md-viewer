import Foundation

/// Which HTML files may run scripts and load content from the internet: files
/// the user trusted one by one, and everything inside folders they trusted.
/// Paths are absolute, without a trailing slash.
public struct TrustList: Equatable, Sendable {
    public var files: Set<String>
    public var folders: Set<String>

    public init(files: Set<String> = [], folders: Set<String> = []) {
        self.files = files
        self.folders = folders
    }

    public func isTrusted(file path: String) -> Bool {
        files.contains(path) || folder(trusting: path) != nil
    }

    /// The trusted folder that contains `path` (the innermost one), if any.
    public func folder(trusting path: String) -> String? {
        folders.filter { path.hasPrefix(Self.prefix(of: $0)) }.max { $0.count < $1.count }
    }

    /// Whether `folder` is trusted itself or sits inside a trusted folder.
    public func covers(folder path: String) -> Bool {
        folders.contains(path) || folder(trusting: path) != nil
    }

    /// "/a/b" matches "/a/b/..." but not "/a/bc/...".
    private static func prefix(of folder: String) -> String {
        folder.hasSuffix("/") ? folder : folder + "/"
    }
}
