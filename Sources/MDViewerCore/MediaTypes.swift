import Foundation

/// MIME types for the files the preview loads.
public enum MediaTypes {
    /// Local files a markdown document may embed: images, audio and video.
    /// Anything else is refused, so a document cannot pull arbitrary files into the page.
    public static let embeddable: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif", "bmp": "image/bmp",
        "ico": "image/x-icon", "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic",
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "ogg": "audio/ogg",
    ]

    /// The app's own web assets (the preview page, its scripts and styles).
    public static let webAssets: [String: String] = [
        "html": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json",
        "svg": "image/svg+xml", "png": "image/png", "woff2": "font/woff2", "txt": "text/plain",
    ]

    public static func embeddableType(for url: URL) -> String? {
        embeddable[url.pathExtension.lowercased()]
    }

    public static func webAssetType(for url: URL) -> String? {
        webAssets[url.pathExtension.lowercased()]
    }
}
