import Foundation

/// One row in the sidebar: a document, or a folder that holds documents.
public struct FolderEntry: Sendable, Hashable {
    public let url: URL
    public let isDirectory: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    public var name: String { url.lastPathComponent }
}

/// Lists the markdown and HTML files in a folder for the sidebar.
public enum FolderScanner {
    /// Folders that are never worth browsing for documents (dependencies, caches).
    /// Hidden folders such as .git are skipped too.
    public static let skippedFolderNames: Set<String> = [
        "node_modules", "bower_components", "__pycache__", "site-packages", "venv", "DerivedData", "Pods",
    ]

    /// The documents directly inside `folder`, and its subfolders that contain documents.
    /// Folders come first; both are sorted the way Finder sorts names.
    public static func entries(in folder: URL) -> [FolderEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [FolderEntry] = []
        var files: [FolderEntry] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if values?.isPackage == true || skippedFolderNames.contains(url.lastPathComponent) { continue }
                if containsDocuments(url) { folders.append(FolderEntry(url: url, isDirectory: true)) }
            } else if DocumentKind(url: url) != nil {
                files.append(FolderEntry(url: url, isDirectory: false))
            }
        }
        let byName: (FolderEntry, FolderEntry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    /// Whether `folder` holds a document within `maxDepth` levels. After looking
    /// at `budget` items it gives up and answers yes, so huge trees stay fast.
    public static func containsDocuments(_ folder: URL, maxDepth: Int = 4, budget: Int = 800) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            seen += 1
            if seen > budget { return true }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if enumerator.level >= maxDepth || skippedFolderNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
            } else if DocumentKind(url: url) != nil {
                return true
            }
        }
        return false
    }
}
