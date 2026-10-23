import AppKit

/// Asks before trusting a whole folder of HTML files.
@MainActor
enum TrustPrompt {
    static func confirmTrusting(_ folder: URL, in window: NSWindow?, then trust: @escaping @MainActor () -> Void) {
        let name = folder.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Trust all HTML files in “\(name)”?"
        alert.informativeText = "Scripts in HTML files in this folder and its subfolders will run and can load content from the internet, including files added later. Trust only folders whose files you control."
        if isBroad(folder) {
            alert.alertStyle = .critical
            alert.informativeText = "“\(name)” is a broad folder that may hold files from the internet or from other people. " + alert.informativeText
        }
        alert.addButton(withTitle: "Trust Folder")
        alert.addButton(withTitle: "Cancel")
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { trust() }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            finish(alert.runModal())
        }
    }

    /// Folders where files from anywhere collect: worth a stronger warning.
    private static func isBroad(_ folder: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/")
        let path = folder.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let broad = ["/", "/Users", home] + ["Downloads", "Desktop", "Documents", "Library/Mobile Documents/com~apple~CloudDocs"].map { home + "/" + $0 }
        return broad.contains(path)
    }
}
