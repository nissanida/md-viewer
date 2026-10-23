import Foundation
import MDViewerCore

/// Settings remembered between launches.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let lastFolder = "lastFolder"
        static let lastFile = "lastFile"
        static let viewMode = "viewMode"
        static let sidebarVisible = "sidebarVisible"
        static let outlineVisible = "outlineVisible"
        static let terminalVisible = "terminalVisible"
        static let zoom = "zoom"
        static let trustedHTMLFiles = "trustedHTMLFiles"
        static let trustedFolders = "trustedFolders"
        static let autoStartClaude = "autoStartClaude"
        static let recentItems = "recentItems"
        static let launchCount = "launchCount"
        static let defaultAppOfferAnswered = "defaultAppOfferAnswered"
    }

    static var lastFolder: URL? {
        get { defaults.string(forKey: Key.lastFolder).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path(percentEncoded: false), forKey: Key.lastFolder) }
    }

    static var lastFile: URL? {
        get { defaults.string(forKey: Key.lastFile).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path(percentEncoded: false), forKey: Key.lastFile) }
    }

    static var viewMode: ViewMode {
        get { defaults.string(forKey: Key.viewMode).flatMap(ViewMode.init(rawValue:)) ?? .preview }
        set { defaults.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    static var sidebarVisible: Bool {
        get { defaults.bool(forKey: Key.sidebarVisible) }
        set { defaults.set(newValue, forKey: Key.sidebarVisible) }
    }

    static var outlineVisible: Bool {
        get { defaults.bool(forKey: Key.outlineVisible) }
        set { defaults.set(newValue, forKey: Key.outlineVisible) }
    }

    static var terminalVisible: Bool {
        get { defaults.bool(forKey: Key.terminalVisible) }
        set { defaults.set(newValue, forKey: Key.terminalVisible) }
    }

    static var zoom: Double {
        get { defaults.object(forKey: Key.zoom) as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: Key.zoom) }
    }

    /// How many times the app has started; the default-app offer waits for the second.
    static var launchCount: Int {
        get { defaults.integer(forKey: Key.launchCount) }
        set { defaults.set(newValue, forKey: Key.launchCount) }
    }

    /// Whether the user answered the one-time "make MD Viewer the default" offer.
    static var defaultAppOfferAnswered: Bool {
        get { defaults.bool(forKey: Key.defaultAppOfferAnswered) }
        set { defaults.set(newValue, forKey: Key.defaultAppOfferAnswered) }
    }

    static var autoStartClaude: Bool {
        get { defaults.bool(forKey: Key.autoStartClaude) }
        set { defaults.set(newValue, forKey: Key.autoStartClaude) }
    }

    /// Posted when the user trusts or stops trusting an HTML file or folder.
    static let trustDidChange = Notification.Name("MDViewer.trustDidChange")

    /// HTML files and folders the user allowed to run scripts and load remote content.
    static var trust: TrustList {
        TrustList(files: Set(defaults.stringArray(forKey: Key.trustedHTMLFiles) ?? []),
                  folders: Set(defaults.stringArray(forKey: Key.trustedFolders) ?? []))
    }

    /// Trusted on its own or through a trusted folder.
    static func isTrusted(_ file: URL) -> Bool {
        trust.isTrusted(file: path(file))
    }

    /// Trusted on its own (rather than through a folder).
    static func isFileTrusted(_ file: URL) -> Bool {
        trust.files.contains(path(file))
    }

    /// The trusted folder that makes `file` trusted, if any.
    static func trustingFolder(for file: URL) -> URL? {
        trust.folder(trusting: path(file)).map { URL(fileURLWithPath: $0) }
    }

    static func isFolderTrusted(_ folder: URL) -> Bool {
        trust.covers(folder: path(folder))
    }

    static var trustedFolders: [URL] {
        trust.folders.sorted().map { URL(fileURLWithPath: $0) }
    }

    static func setTrusted(_ trusted: Bool, for file: URL) {
        update(Key.trustedHTMLFiles, path(file), trusted)
    }

    static func setFolderTrusted(_ trusted: Bool, _ folder: URL) {
        update(Key.trustedFolders, path(folder), trusted)
    }

    private static func update(_ key: String, _ path: String, _ include: Bool) {
        var paths = Set(defaults.stringArray(forKey: key) ?? [])
        if include { paths.insert(path) } else { paths.remove(path) }
        defaults.set(paths.sorted(), forKey: key)
        NotificationCenter.default.post(name: trustDidChange, object: nil)
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }

    /// Recently opened files and folders, newest first.
    static var recentItems: [URL] {
        (defaults.stringArray(forKey: Key.recentItems) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func noteRecent(_ url: URL) {
        let path = url.path(percentEncoded: false)
        var paths = defaults.stringArray(forKey: Key.recentItems) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: Key.recentItems)
    }

    static func clearRecents() {
        defaults.removeObject(forKey: Key.recentItems)
    }
}

/// How the current document is shown.
enum ViewMode: String {
    /// The rendered document.
    case preview
    /// The raw text, editable.
    case source
    /// Raw text and live preview side by side (markdown only).
    case split
}
