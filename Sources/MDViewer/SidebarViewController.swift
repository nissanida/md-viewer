import AppKit
import MDViewerCore

/// A file or folder in the sidebar. Folders load their contents when first expanded.
@MainActor
final class SidebarNode {
    let url: URL
    let isDirectory: Bool
    private(set) var children: [SidebarNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    func loadedChildren() -> [SidebarNode] {
        if let children { return children }
        let loaded = FolderScanner.entries(in: url).map { SidebarNode(url: $0.url, isDirectory: $0.isDirectory) }
        children = loaded
        return loaded
    }

    /// Re-reads the folder, reusing existing nodes so expanded folders stay expanded.
    func refresh() {
        guard let current = children else { return }
        let existing = Dictionary(current.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        children = FolderScanner.entries(in: url).map {
            existing[$0.url.standardizedFileURL] ?? SidebarNode(url: $0.url, isDirectory: $0.isDirectory)
        }
    }
}

/// The collapsible file list: the markdown and HTML files in the open folder.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpen: ((URL) -> Void)?

    private let outlineView = NSOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var root: SidebarNode?
    private var selectedFile: URL?
    private var isSelectingProgrammatically = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel("Files")
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let root = NSView()
        for view in [titleLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    // MARK: Public

    var folder: URL? { root?.url }

    func setFolder(_ folder: URL?) {
        guard folder?.standardizedFileURL != root?.url else { return }
        root = folder.map { SidebarNode(url: $0, isDirectory: true) }
        titleLabel.stringValue = folder?.lastPathComponent.uppercased() ?? ""
        titleLabel.toolTip = folder?.path(percentEncoded: false)
        outlineView.reloadData()
    }

    /// Highlights `file`, expanding the folders above it.
    func reveal(_ file: URL?) {
        selectedFile = file?.standardizedFileURL
        guard let file = selectedFile, let root else { return outlineView.deselectAll(nil) }
        let filePath = file.path(percentEncoded: false)

        // Walk down through the folders that contain the file, expanding each.
        var node = root
        while true {
            let children = node.loadedChildren()
            if let match = children.first(where: { $0.url == file }) {
                let row = outlineView.row(forItem: match)
                guard row >= 0 else { return }
                isSelectingProgrammatically = true
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                isSelectingProgrammatically = false
                return
            }
            guard let folder = children.first(where: {
                $0.isDirectory && filePath.hasPrefix($0.url.path(percentEncoded: false).trimmingSuffix("/") + "/")
            }) else { return outlineView.deselectAll(nil) }
            outlineView.expandItem(folder)
            node = folder
        }
    }

    /// Updates the folders affected by files that changed on disk.
    func filesChanged(_ paths: [String]) {
        guard let root else { return }
        let rootPath = root.url.path(percentEncoded: false).trimmingSuffix("/")
        var refreshed = Set<ObjectIdentifier>()
        for path in paths where path.hasPrefix(rootPath) {
            // Refresh every loaded folder from the root down to the change: a new
            // file can also make a parent folder appear for the first time.
            var node: SidebarNode? = root
            while let current = node {
                if refreshed.insert(ObjectIdentifier(current)).inserted {
                    current.refresh()
                    outlineView.reloadItem(current === root ? nil : current, reloadChildren: true)
                }
                node = current.children?.first { $0.isDirectory && path.hasPrefix($0.url.path(percentEncoded: false).trimmingSuffix("/") + "/") }
            }
        }
        if !refreshed.isEmpty { reveal(selectedFile) }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item)?.loadedChildren().count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item)!.loadedChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isDirectory ?? false
    }

    private func node(_ item: Any?) -> SidebarNode? {
        item == nil ? root : item as? SidebarNode
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
        cell.textField?.stringValue = node.name
        let symbol = node.isDirectory ? "folder" : (DocumentKind(url: node.url) == .html ? "globe" : "doc.text")
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.toolTip = node.url.path(percentEncoded: false)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode,
              !node.isDirectory else { return }
        selectedFile = node.url
        onOpen?(node.url)
    }

    /// Clicking a folder's name opens or closes it, like its disclosure arrow.
    @objc private func rowClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode, node.isDirectory else { return }
        if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for view in [image, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Drops onto the list open the file

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        droppedFiles(info).isEmpty ? [] : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let files = droppedFiles(info)
        guard let first = files.first else { return false }
        onOpen?(first)
        return true
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealClicked(_:)), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copyPathClicked(_:)), keyEquivalent: "")
        for item in [reveal, copy] {
            item.target = self
            item.representedObject = node.url
            menu.addItem(item)
        }
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPathClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path(percentEncoded: false), forType: .string)
    }
}

/// The outline of the current document's headings; clicking one scrolls to it.
@MainActor
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((OutlineItem) -> Void)?

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No headings")
    private var items: [OutlineItem] = []
    private var baseLevel = 1

    override func loadView() {
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading")))
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel("Outline")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let title = NSTextField(labelWithString: "OUTLINE")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        let root = NSView()
        for view in [title, scrollView, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            emptyLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        ])
        view = root
    }

    func show(_ outline: [OutlineItem]) {
        guard outline != items else { return }
        items = outline
        baseLevel = outline.map(\.level).min() ?? 1
        emptyLabel.isHidden = !outline.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let label = NSTextField(labelWithString: item.text)
        label.lineBreakMode = .byTruncatingTail
        let depth = item.level - baseLevel
        label.font = depth == 0 ? .systemFont(ofSize: 12.5, weight: .semibold) : .systemFont(ofSize: 12.5)
        label.textColor = depth <= 1 ? .labelColor : .secondaryLabelColor
        label.toolTip = item.text
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4 + CGFloat(min(depth, 4)) * 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onSelect?(items[row])
    }
}
