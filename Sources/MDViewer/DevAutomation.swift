import AppKit
import MDViewerCore
@preconcurrency import SwiftTerm
import WebKit

/// Lets scripts drive the app while developing it: take a snapshot of the
/// window, run a menu action, open a file, switch light/dark mode.
///
/// Off unless the app is launched with MDV_AUTOMATION=1 (see scripts/automate.swift).
/// Opening the app from Finder, the Dock or `open` never enables it.
@MainActor
enum DevAutomation {
    static let notification = Notification.Name("dev.mdviewer.automation")

    static func startIfEnabled(_ windowController: MainWindowController) {
        guard ProcessInfo.processInfo.environment["MDV_AUTOMATION"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            // The command travels in `object` as "action argument".
            guard let command = note.object as? String else { return }
            let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
            MainActor.assumeIsolated {
                run(parts[0], parts.count > 1 ? parts[1] : "", windowController)
            }
        }
        NSLog("MD Viewer: automation enabled")
    }

    /// While developing, with automation on: a stand-in for `claude`
    /// (MDV_CLAUDE_PATH) and a cheaper model (MDV_CLAUDE_MODEL) for the chat.
    nonisolated static var claudePath: String? { setting("MDV_CLAUDE_PATH") }
    nonisolated static var claudeModel: String? { setting("MDV_CLAUDE_MODEL") }

    private nonisolated static func setting(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["MDV_AUTOMATION"] == "1", let value = env[name], !value.isEmpty else { return nil }
        return value
    }

    private static func run(_ action: String, _ argument: String, _ windowController: MainWindowController) {
        switch action {
        case "snapshot": snapshot(windowController.window, to: URL(fileURLWithPath: argument), redrawing: [windowController.chat.view])
        case "terminal-text": writeTerminalText(windowController.window, to: URL(fileURLWithPath: argument))
        case "action":
            // Straight to the window controller: the menu's usual route (the key
            // window) doesn't exist while another app is in front.
            let selector = NSSelectorFromString(argument)
            NSApp.sendAction(selector, to: windowController.responds(to: selector) ? windowController : nil, from: nil)
        case "full-screen": windowController.window?.toggleFullScreen(nil)
        case "close-window": windowController.window?.performClose(nil) // the red button
        case "window-state": // "visible fullscreen" flags, written to the file
            let window = windowController.window
            let state = "visible=\(window?.isVisible == true) fullscreen=\(window?.styleMask.contains(.fullScreen) == true)"
            try? state.write(to: URL(fileURLWithPath: argument), atomically: true, encoding: .utf8)
        case "open": windowController.open([URL(fileURLWithPath: argument)])
        case "export-pdf": windowController.exportPDF(to: URL(fileURLWithPath: argument))
        case "editor-insert": // types into the source editor (only when it has focus)
            if let textView = windowController.window?.firstResponder as? NSTextView, textView.isEditable {
                textView.insertText(argument.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: textView.selectedRange())
            }
        case "key": // a key press through normal event handling, e.g. "ctrl+`", "cmd+shift+o"
            if let event = keyEvent(argument, window: windowController.window) { NSApp.sendEvent(event) }
        case "focus": // gives keyboard focus to "terminal" or "document"
            guard let window = windowController.window, let frameView = window.contentView?.superview else { return }
            let target: NSView? = argument == "terminal"
                ? allSubviews(of: frameView).first { $0 is TerminalView }
                : allSubviews(of: frameView).first { ($0 is WKWebView || $0 is NSTextView) && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
            if let target { window.makeFirstResponder(target) }
        case "menu-dump": // every menu item with its shortcut and action, as a table
            var lines: [String] = []
            func walk(_ menu: NSMenu, _ path: String) {
                menu.delegate?.menuNeedsUpdate?(menu) // submenus built when they open
                menu.update() // runs validation, so titles, checkmarks and enabled states are current
                for item in menu.items where !item.isSeparatorItem {
                    if let submenu = item.submenu { walk(submenu, path + item.title + " > ") ; continue }
                    let mods = item.keyEquivalentModifierMask
                    let keys = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "")
                    let key = item.keyEquivalent.isEmpty ? "" : keys + item.keyEquivalent.uppercased()
                    let flags = (item.isHidden ? " (hidden)" : "") + (item.isEnabled ? "" : " (disabled)") + (item.state == .on ? " (checked)" : "")
                    lines.append("\(path)\(item.title)\t\(key)\t\(item.action.map(NSStringFromSelector) ?? "-")\(flags)")
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            try? lines.joined(separator: "\n").write(toFile: argument, atomically: true, encoding: .utf8)
        case "click": // presses the button with this title (banner buttons, for example)
            // Looks in an open sheet (an alert) first, then in the window.
            let roots = [windowController.window?.attachedSheet, windowController.window].compactMap { $0?.contentView?.superview }
            let views = roots.flatMap(allSubviews).filter { !$0.isHiddenOrHasHiddenAncestor }
            if let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == argument }) {
                button.performClick(nil)
            } else if let pill = views.compactMap({ $0 as? ChatPillButton }).first(where: { $0.title == argument }) {
                _ = pill.accessibilityPerformPress() // the chat's own pill buttons
            }
        case "eval": // "eval /path/to/output.txt|javascript"
            let pieces = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let frameView = windowController.window?.contentView?.superview,
                  let webView = allSubviews(of: frameView).compactMap({ $0 as? WKWebView }).first(where: { !$0.isHiddenOrHasHiddenAncestor })
            else { return }
            Task { @MainActor in
                let result = try? await webView.callAsyncJavaScript(pieces[1], contentWorld: .page)
                try? String(describing: result ?? "nil").write(toFile: pieces[0], atomically: true, encoding: .utf8)
            }
        case "scroll":
            guard let frameView = windowController.window?.contentView?.superview else { return }
            for webView in allSubviews(of: frameView).compactMap({ $0 as? WKWebView }) where !webView.isHiddenOrHasHiddenAncestor {
                webView.evaluateJavaScript("window.scrollTo(0, \(Double(argument) ?? 0))")
            }
        case "chat-type": // puts text in the chat's message box ("\n" for a new line)
            windowController.chat.typeForAutomation(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "chat-send": // sends a message, as if typed and sent
            windowController.chat.send(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "chat-stop":
            windowController.chat.stop()
        case "chat-options": // "model=opus effort=high auto=on", as if chosen under the message box
            var settings = ChatSettings()
            for pair in argument.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "model": settings.model = parts[1]
                case "effort": settings.effort = parts[1] == "default" ? nil : parts[1]
                case "auto": settings.autoMode = parts[1] == "on"
                default: break
                }
            }
            windowController.chat.chooseForAutomation(settings)
        case "chat-new":
            windowController.chat.newChat()
        case "chat-eval": // "chat-eval /path/to/output.txt|javascript", in the chat's transcript page
            let pieces = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return }
            let webView = windowController.chat.transcriptWebView
            Task { @MainActor in
                let result = try? await webView.callAsyncJavaScript(pieces[1], contentWorld: .page)
                try? String(describing: result ?? "nil").write(toFile: pieces[0], atomically: true, encoding: .utf8)
            }
        case "chat-state": // the chat's items, approvals and notice, as JSON
            let state = windowController.chat.automationState()
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: argument))
            }
        case "appearance": NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "resize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            if size.count == 2 { windowController.window?.setContentSize(NSSize(width: size[0], height: size[1])) }
        default: NSLog("MD Viewer: unknown automation action \(action)")
        }
    }

    private static func keyEvent(_ spec: String, window: NSWindow?) -> NSEvent? {
        let codes: [String: UInt16] = [
            "a": 0, "s": 1, "f": 3, "g": 5, "e": 14, "o": 31, "p": 35, "j": 38, "1": 18, "2": 19, "3": 20,
            "=": 24, "-": 27, "0": 29, "/": 44, "`": 50, "return": 36, "escape": 53,
        ]
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast(), let code = codes[key] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            default: break
            }
        }
        let characters = key == "return" ? "\r" : key == "escape" ? "\u{1b}" : key
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// Writes the terminal's visible lines to a text file.
    private static func writeTerminalText(_ window: NSWindow?, to url: URL) {
        guard let frameView = window?.contentView?.superview,
              let view = allSubviews(of: frameView).compactMap({ $0 as? TerminalView }).first else { return }
        let terminal = view.getTerminal()
        let lines = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        let layers = (view.layer?.sublayers ?? []).map {
            "\(type(of: $0)) opaque=\($0.isOpaque) bg=\(String(describing: $0.backgroundColor)) contents=\(String(describing: $0.contents.map { type(of: $0) })) frame=\($0.frame)"
        }
        let colors = "# background \(view.nativeBackgroundColor)\n# " + layers.joined(separator: "\n# ")
        try? ([colors] + lines).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Draws the window into a PNG. Web views render in another process and the
    /// terminal draws straight into layers, so those are layered over the AppKit drawing.
    /// - Parameter redrawing: panels drawn again on their own: the window's drawing
    ///   can leave out the strip of a full-height panel just under the toolbar.
    private static func snapshot(_ window: NSWindow?, to url: URL, redrawing panels: [NSView] = []) {
        guard let frameView = window?.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        let panelShots: [(NSBitmapImageRep, NSRect)] = panels.compactMap { panel in
            guard panel.window != nil, !panel.isHiddenOrHasHiddenAncestor, panel.bounds.width > 0,
                  let panelRep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return nil }
            panel.cacheDisplay(in: panel.bounds, to: panelRep)
            return (panelRep, panel.convert(panel.bounds, to: frameView))
        }

        let webViews = allSubviews(of: frameView).compactMap { $0 as? WKWebView }.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
        Task { @MainActor in
            var webShots: [(NSImage, NSRect)] = []
            for webView in webViews {
                if let shot = try? await webView.takeSnapshot(configuration: nil) {
                    webShots.append((shot, webView.convert(webView.bounds, to: frameView)))
                }
            }
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            rep.draw(in: bounds)
            for (panelRep, rect) in panelShots {
                // Blended over the window, since the panel's own drawing is see-through where it has no background.
                panelRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // The terminal draws into layers whose contents can't be read back, so
            // snapshots show its text on black; the real view uses the theme colors.
            for terminal in allSubviews(of: frameView).compactMap({ $0 as? TerminalView }) where !terminal.isHiddenOrHasHiddenAncestor {
                guard let layer = terminal.layer, let context = NSGraphicsContext.current?.cgContext else { continue }
                let rect = terminal.convert(terminal.bounds, to: frameView)
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                layer.render(in: context)
                context.restoreGState()
            }
            for (shot, rect) in webShots { shot.draw(in: rect) }
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                NSLog("MD Viewer: snapshot written to \(url.path)")
            }
        }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
