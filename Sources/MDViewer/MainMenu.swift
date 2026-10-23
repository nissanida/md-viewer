import AppKit

/// Selectors for menu item actions (nothing conforms to this; it only names them).
/// Items have no fixed target, so AppKit delivers
/// each action to the first object in the responder chain that implements it:
/// the text view, terminal or window controller in focus, then the app delegate.
@objc protocol MenuActions {
    // App delegate: work even when no window is open.
    @objc optional func openDocument(_ sender: Any?)
    @objc optional func openFolder(_ sender: Any?)
    @objc optional func openRecentItem(_ sender: NSMenuItem)
    @objc optional func clearRecentItems(_ sender: Any?)
    @objc optional func openClaudeCodeDocs(_ sender: Any?)
    @objc optional func makeDefaultForMarkdown(_ sender: Any?)
    @objc optional func makeDefaultForHTML(_ sender: Any?)

    // Window controller.
    @objc optional func saveDocument(_ sender: Any?)
    @objc optional func reloadFromDisk(_ sender: Any?)
    @objc optional func revealInFinder(_ sender: Any?)
    @objc optional func exportPDF(_ sender: Any?)
    @objc optional func printDocument(_ sender: Any?)
    @objc optional func showPreview(_ sender: Any?)
    @objc optional func showSource(_ sender: Any?)
    @objc optional func showSplit(_ sender: Any?)
    @objc optional func toggleSourceView(_ sender: Any?)
    @objc optional func toggleEditMode(_ sender: Any?)
    @objc optional func performFindAction(_ sender: Any?)
    @objc optional func toggleSidebarPanel(_ sender: Any?)
    @objc optional func toggleOutline(_ sender: Any?)
    @objc optional func toggleTerminal(_ sender: Any?)
    @objc optional func zoomIn(_ sender: Any?)
    @objc optional func zoomOut(_ sender: Any?)
    @objc optional func resetZoom(_ sender: Any?)
    @objc optional func toggleTrust(_ sender: Any?)
    @objc optional func trustCurrentFolder(_ sender: Any?)
    @objc optional func stopTrustingFolder(_ sender: NSMenuItem)
    @objc optional func startClaude(_ sender: Any?)
    @objc optional func sendFilePathToTerminal(_ sender: Any?)
    @objc optional func sendSelectionToTerminal(_ sender: Any?)
    @objc optional func newShellHere(_ sender: Any?)
    @objc optional func toggleAutoStartClaude(_ sender: Any?)
}

@MainActor
enum MainMenu {
    /// Submenus filled in by the delegate each time they open.
    static let recentItemsMenu = NSUserInterfaceItemIdentifier("recentItems")
    static let trustedFoldersMenu = NSUserInterfaceItemIdentifier("trustedFolders")

    static func build(delegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(delegate: delegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu(delegate: delegate)))
        main.addItem(submenu(terminalMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName == "MDViewer" ? "MD Viewer" : ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // Titles and checkmarks are updated by the app delegate each time the menu opens.
        menu.addItem(item("Make Default for Markdown Files", #selector(MenuActions.makeDefaultForMarkdown(_:))))
        menu.addItem(item("Make Default for HTML Files", #selector(MenuActions.makeDefaultForHTML(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(delegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(MenuActions.openDocument(_:)), "o"))
        menu.addItem(item("Open Folder…", #selector(MenuActions.openFolder(_:)), "o", [.command, .shift]))
        let recents = NSMenu(title: "Open Recent")
        recents.identifier = recentItemsMenu
        recents.delegate = delegate
        menu.addItem(submenu(recents))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(MenuActions.saveDocument(_:)), "s"))
        menu.addItem(item("Reload from Disk", #selector(MenuActions.reloadFromDisk(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Reveal in Finder", #selector(MenuActions.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Export as PDF…", #selector(MenuActions.exportPDF(_:))))
        menu.addItem(item("Print…", #selector(MenuActions.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        // The window controller routes these to whatever has focus: the source
        // editor's and the terminal's native find bars, or the preview's find bar.
        let find = NSMenu(title: "Find")
        let finder = #selector(MenuActions.performFindAction(_:))
        find.addItem(item("Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(item("Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(item("Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(item("Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        menu.addItem(submenu(find))
        return menu
    }

    private static func viewMenu(delegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Preview", #selector(MenuActions.showPreview(_:)), "1"))
        menu.addItem(item("Source", #selector(MenuActions.showSource(_:)), "2"))
        menu.addItem(item("Edit with Live Preview", #selector(MenuActions.showSplit(_:)), "3"))
        menu.addItem(item("Toggle Source", #selector(MenuActions.toggleSourceView(_:)), "/"))
        menu.addItem(.separator())
        menu.addItem(item("Show Sidebar", #selector(MenuActions.toggleSidebarPanel(_:)), "s", [.command, .control]))
        menu.addItem(item("Show Outline", #selector(MenuActions.toggleOutline(_:)), "o", [.command, .control]))
        menu.addItem(item("Show Terminal", #selector(MenuActions.toggleTerminal(_:)), "`", [.control]))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(MenuActions.resetZoom(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(MenuActions.zoomIn(_:)), "="))
        let zoomInPlus = item("Zoom In", #selector(MenuActions.zoomIn(_:)), "+") // ⌘+ as well as ⌘=
        zoomInPlus.isHidden = true
        zoomInPlus.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInPlus)
        menu.addItem(item("Zoom Out", #selector(MenuActions.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Allow Scripts and Remote Content", #selector(MenuActions.toggleTrust(_:))))
        let trusted = NSMenu(title: "Trusted Folders")
        trusted.identifier = trustedFoldersMenu
        trusted.delegate = delegate
        menu.addItem(submenu(trusted))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func terminalMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.addItem(item("Start Claude Code", #selector(MenuActions.startClaude(_:)), "`", [.control, .shift]))
        menu.addItem(item("Send File Path to Terminal", #selector(MenuActions.sendFilePathToTerminal(_:)), "p", [.command, .option]))
        menu.addItem(item("Send Selection to Terminal", #selector(MenuActions.sendSelectionToTerminal(_:)), "j", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("New Shell in Open Folder", #selector(MenuActions.newShellHere(_:))))
        menu.addItem(item("Start Claude Code Automatically", #selector(MenuActions.toggleAutoStartClaude(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Claude Code Documentation", #selector(MenuActions.openClaudeCodeDocs(_:))))
        return menu
    }

    // MARK: Helpers

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
