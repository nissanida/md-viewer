import Foundation

/// Converts between file URLs and the `mdv-file://local/<path>` URLs the
/// markdown preview uses for local images and links. The preview web view has
/// no direct file access; the app serves these URLs itself.
public enum LocalFileURL {
    public static let scheme = "mdv-file"

    public static func make(for fileURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        components.path = fileURL.path(percentEncoded: false)
        return components.url!
    }

    /// The file a `mdv-file:` URL points to, without its query or fragment.
    public static func fileURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host() == "local" else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

/// Resolves symlinks the way FSEvents reports paths (for example /var -> /private/var),
/// so paths from different sources can be compared.
public func canonicalPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    guard let resolved = realpath(path, nil) else { return url.standardizedFileURL.path(percentEncoded: false) }
    defer { free(resolved) }
    return String(cString: resolved)
}
