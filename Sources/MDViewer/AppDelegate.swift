import AppKit
import MDViewerCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController!
    private var openedFilesAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.launchCount += 1 // before any file opens, so it counts for this launch
        NSApp.mainMenu = MainMenu.build(delegate: self)
        windowController = MainWindowController()
        DevAutomation.startIfEnabled(windowController)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Paths passed on the command line (`MDViewer file.md` during development).
        let arguments = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
        }
        if !arguments.isEmpty {
            windowController.open(arguments.map { URL(fileURLWithPath: $0).standardizedFileURL })
        } else if !openedFilesAtLaunch {
            windowController.restoreLastSession()
        }
        windowController.showWindow(nil)
        NSApp.activate()
    }

    /// Files and folders opened from Finder, the Dock icon or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        windowController.open(urls)
        windowController.showWindow(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController.confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController.saveSession()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = windowController.currentFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowController.open([url])
        windowController.showWindow(nil)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = windowController.currentFolder
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowController.open([url])
        windowController.showWindow(nil)
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        windowController.open([url])
        windowController.showWindow(nil)
    }

    @objc func clearRecentItems(_ sender: Any?) {
        Preferences.clearRecents()
    }

    @objc func openClaudeCodeDocs(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs")!)
    }

    // MARK: Default app

    @objc func makeDefaultForMarkdown(_ sender: Any?) {
        makeDefault(.markdown)
    }

    @objc func makeDefaultForHTML(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open HTML files with MD Viewer?"
        alert.informativeText = "HTML files you open from Finder or other apps will show in MD Viewer, with scripts off until you trust each file. Web links still open in your browser. To switch back, use Get Info > Open with > Change All in Finder."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        makeDefault(.html)
    }

    private func makeDefault(_ kind: DocumentKind) {
        Task {
            do {
                try await DefaultApp.makeDefault(for: kind)
            } catch {
                let alert = NSAlert()
                alert.messageText = "MD Viewer couldn’t be made the default app."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(makeDefaultForMarkdown(_:)):
            return validateDefaultItem(item, kind: .markdown, name: "Markdown")
        case #selector(makeDefaultForHTML(_:)):
            return validateDefaultItem(item, kind: .html, name: "HTML")
        case #selector(clearRecentItems(_:)):
            return !Preferences.recentItems.isEmpty
        default:
            return true
        }
    }

    /// Shows "Default App for … Files" with a checkmark once it is the default.
    private func validateDefaultItem(_ item: NSMenuItem, kind: DocumentKind, name: String) -> Bool {
        let isDefault = DefaultApp.isDefault(for: kind)
        item.title = isDefault ? "Default App for \(name) Files" : "Make Default for \(name) Files"
        item.state = isDefault ? .on : .off
        return !isDefault && DefaultApp.canChange
    }

    private static var openableTypes: [UTType] {
        let extensions = DocumentKind.markdownExtensions.union(DocumentKind.htmlExtensions)
        return extensions.compactMap { UTType(filenameExtension: $0) } + [.html, .plainText]
    }

    // MARK: Submenus filled when they open

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier {
        case MainMenu.recentItemsMenu: fillRecentItems(menu)
        case MainMenu.trustedFoldersMenu: fillTrustedFolders(menu)
        default: break
        }
    }

    /// "Trust “folder”…" for the open folder, then one "Stop Trusting" item per trusted folder.
    private func fillTrustedFolders(_ menu: NSMenu) {
        menu.removeAllItems()
        // Sent to the window controller, which names the open folder in its title.
        menu.addItem(NSMenuItem(title: "Trust Open Folder…", action: #selector(MenuActions.trustCurrentFolder(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let folders = Preferences.trustedFolders
        if folders.isEmpty {
            menu.addItem(NSMenuItem(title: "No Trusted Folders", action: nil, keyEquivalent: ""))
        }
        for folder in folders {
            let item = NSMenuItem(title: "Stop Trusting “\(folder.lastPathComponent)”", action: #selector(stopTrustingFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            item.toolTip = folder.path(percentEncoded: false)
            menu.addItem(item)
        }
    }

    @objc func stopTrustingFolder(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? URL { Preferences.setFolderTrusted(false, folder) }
    }

    private func fillRecentItems(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = Preferences.recentItems.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
            item.image?.size = NSSize(width: 16, height: 16)
            item.toolTip = url.path(percentEncoded: false)
            menu.addItem(item)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentItems(_:)), keyEquivalent: "")
        clear.isEnabled = !recents.isEmpty
        menu.addItem(clear)
    }
}
