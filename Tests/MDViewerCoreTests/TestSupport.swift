import Foundation

/// A fresh folder under the system temp directory, removed when released.
final class TemporaryFolder {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MDViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // FSEvents reports canonical paths (/private/var/...), so work with those.
        url = URL(fileURLWithPath: base.resolvingSymlinksInPath().path).standardizedFileURL
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ text: String, to name: String) throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: false, encoding: .utf8)
        return file
    }
}
