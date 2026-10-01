import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelect scratch: Scratch)
    func sidebarContextMenu(_ sidebar: SidebarViewController, for scratches: [Scratch]) -> NSMenu
    /// A sidebar-scoped shortcut (see `ActionScope.sidebar`) was pressed.
    func sidebar(_ sidebar: SidebarViewController, perform actionId: String)
    func sidebar(_ sidebar: SidebarViewController, importFiles urls: [URL], into folder: String)
    func sidebar(_ sidebar: SidebarViewController, rename scratch: Scratch, to name: String)
    func sidebar(_ sidebar: SidebarViewController, renameFolder folder: ScratchFolder, to name: String)
    func sidebar(_ sidebar: SidebarViewController, move scratches: [Scratch], folders: [ScratchFolder], to folder: String)
    /// Menu for a folder row, or for the empty area below the list when `folder` is nil.
    func sidebarFolderMenu(_ sidebar: SidebarViewController, for folder: ScratchFolder?) -> NSMenu
    func sidebar(_ sidebar: SidebarViewController, openTool id: String)
}

private final class Node: NSObject {
    let scratch: Scratch?
    let folder: ScratchFolder?
    let tool: DevTool?
    /// Set on group and folder rows; also the key remembered in `collapsedGroups`.
    let groupKey: String?
    let groupTitle: String
    var children: [Node] = []
    /// Only top-level section headers use the pinned source-list group style.
    var isTopLevel = false
    /// The "Shared Packages" and "Dev Tools" folders, which aren't directories in the scratches folder.
    var isSpecial = false

    /// Type/date section headers (folders are ordinary expandable rows).
    var isGroup: Bool { groupKey != nil && folder == nil && !isSpecial }
    var isFolder: Bool { folder != nil }
    var isExpandable: Bool { groupKey != nil }

    /// Scratches inside, including nested folders.
    var scratchCount: Int { children.reduce(0) { $0 + ($1.scratch != nil ? 1 : $1.scratchCount) } }

    /// All nodes below this one, depth first.
    var descendants: [Node] { children.flatMap { [$0] + $0.descendants } }

    init(scratch: Scratch) {
        self.scratch = scratch
        tool = nil
        folder = nil
        groupKey = nil
        groupTitle = ""
    }

    init(tool: DevTool) {
        scratch = nil
        folder = nil
        self.tool = tool
        groupKey = nil
        groupTitle = tool.title
    }

    init(folder: ScratchFolder, children: [Node]) {
        scratch = nil
        tool = nil
        self.folder = folder
        groupKey = "folder:\(folder.id)"
        groupTitle = folder.name
        self.children = children
    }

    init(key: String, title: String, children: [Node]) {
        scratch = nil
        tool = nil
        folder = nil
        groupKey = key
        groupTitle = title
        self.children = children
    }
}

/// Buckets for "Group by Date Edited", newest first: Today, Yesterday, Previous 7/30 Days, then by month.
private enum DateBucket {
    static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> (rank: Int, key: String, title: String) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return (0, "date:today", "Today") }
        if days == 1 { return (1, "date:yesterday", "Yesterday") }
        if days < 7 { return (2, "date:week", "Previous 7 Days") }
        if days < 30 { return (3, "date:month", "Previous 30 Days") }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 0
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(year == calendar.component(.year, from: now) ? "MMMM" : "MMMM yyyy")
        return (1_000_000 - (year * 12 + month), String(format: "date:%04d-%02d", year, month), formatter.string(from: date))
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: SidebarDelegate?
    fileprivate let outline = SidebarOutlineView()
    private var roots: [Node] = []
    private(set) var scratches: [Scratch] = []
    private let contentSplit = NSSplitView()
    private lazy var folderPane = FolderPaneController(sidebar: self)
    /// The scratch last selected or revealed, re-selected when the folder column changes.
    private var highlighted: Scratch?

    var isFoldersPane: Bool { Settings.shared.foldersPane }
    var filter: FolderFilter { FolderFilter(key: Settings.shared.folderFilter) }
    private var suppressSelection = false
    fileprivate var isRenaming = false
    fileprivate var pendingReload: (() -> Void)?
    private lazy var groupButton = ToolbarStyle.button(symbol: "square.stack.3d.up", tip: "Group Scratches",
                                               target: self, action: #selector(showGroupingMenu))
    private lazy var revealButton = ToolbarStyle.button(
        symbol: "scope", tip: "Reveal Current Scratch (\(KeymapStore.shared.key(for: "revealInSidebar")?.display ?? ""))",
        target: self, action: #selector(revealCurrent))
    private let bar = NSStackView()

    /// Adds a control at the trailing end of the bar above the list.
    func addBarControl(_ control: NSView) {
        bar.addArrangedSubview(control)
    }
    private lazy var foldersButton = ToolbarStyle.button(
        symbol: "folder", tip: "Show Folders Column", target: self, action: #selector(toggleFoldersPane))
    /// Selects package.json in its special folder while it's the open document.
    func setSharedPackagesActive(_ active: Bool) {
        guard active else { return }
        if isFoldersPane, filter != .packages {
            Settings.shared.folderFilter = FolderFilter.packagesKey
            reload(scratches, selectAll: [])
        }
        guard let item = roots.lazy.flatMap({ [$0] + $0.descendants }).first(where: { $0.scratch?.isSharedManifest == true }) else { return }
        expandAncestors(of: item)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        suppressSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        suppressSelection = false
    }

    private static func manifestNode() -> Node { Node(scratch: Scratch(url: SharedPackages.manifest)) }

    private static func sharedPackagesFolder() -> Node {
        let node = Node(key: Self.packagesKey, title: "Shared Packages", children: [manifestNode()])
        node.isSpecial = true
        return node
    }

    private static let packagesKey = "special:packages"
    private static let toolsKey = "special:tools"

    private static func devToolsFolder() -> Node {
        let node = Node(key: toolsKey, title: "Dev Tools", children: DevTools.all.map(Node.init(tool:)))
        node.isSpecial = true
        return node
    }

    /// The dev tool page on screen, highlighted in the list instead of a scratch.
    private(set) var activeTool: String?

    func setActiveTool(_ id: String?) {
        activeTool = id
        guard let id else { return }
        if isFoldersPane, filter != .tools {
            Settings.shared.folderFilter = FolderFilter.toolsKey
            reload(scratches, selectAll: [])
        }
        selectTool(id)
    }

    private func selectTool(_ id: String) {
        guard let item = roots.lazy.flatMap({ [$0] + $0.descendants }).first(where: { $0.tool?.id == id }) else { return }
        expandAncestors(of: item)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        suppressSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        suppressSelection = false
    }

    var grouping: SidebarGrouping { Settings.shared.sidebarGrouping }

    /// Scratches in display order (group order when grouped).
    var orderedScratches: [Scratch] {
        roots.flatMap { [$0] + $0.descendants }.compactMap(\.scratch).filter(\.isInScratchFolder)
    }

    /// Selected scratches that live in the scratches folder (never the shared package.json).
    var selectedScratches: [Scratch] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.scratch }.filter(\.isInScratchFolder)
    }

    var selectedFolders: [ScratchFolder] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.folder }
    }

    /// Where new scratches go: the selected folder, else the selected scratch's folder; nil with no selection.
    var targetFolder: String? {
        if isFoldersPane, let id = filter.folderId { return id }
        if let folder = selectedFolders.first { return folder.id }
        return selectedScratches.first?.folder
    }

    var hasFocus: Bool { view.window?.firstResponder === outline || view.window?.firstResponder === folderPane.outline }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 40
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 8
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onShortcut = { [weak self] combo in
            guard let self, let action = KeymapStore.shared.action(for: combo, scope: .sidebar) else { return false }
            self.delegate?.sidebar(self, perform: action.id)
            return true
        }
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        groupButton.isToggle = true
        foldersButton.isToggle = true
        foldersButton.state = isFoldersPane ? .on : .off

        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.autosaveName = "ScratchPad.sidebarColumns"
        contentSplit.addArrangedSubview(scroll)
        contentSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        if isFoldersPane { installFolderPane() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        [foldersButton, revealButton, groupButton].forEach { ToolbarStyle.makeCompact($0) }
        [foldersButton, revealButton, groupButton, spacer].forEach(bar.addArrangedSubview)
        bar.spacing = 1
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [bar, divider, contentSplit])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in [bar, divider, contentSplit] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        contentSplit.setContentHuggingPriority(.init(1), for: .vertical)
        let root = NSView()
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The window's content runs under the toolbar; keep the controls below it.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        updateGroupButton()
    }

    // MARK: Data

    func reload(_ scratches: [Scratch], select selected: Scratch?) {
        // The file column follows the opened scratch into its folder.
        if isFoldersPane, activeTool == nil, let selected, !filter.includes(selected) {
            Settings.shared.folderFilter = (selected.folder.isEmpty ? FolderFilter.unfiled : .folder(selected.folder)).key
        }
        if let selected { highlighted = selected }
        reload(scratches, selectAll: selected.map { [$0] } ?? [])
    }

    /// Rebuilds the tree, keeping the given scratches selected.
    func reload(_ scratches: [Scratch], selectAll selected: [Scratch]) {
        // Reloading would tear down the cell being renamed; catch up once the rename ends.
        if isRenaming {
            pendingReload = { [weak self] in self?.reload(scratches, selectAll: selected) }
            return
        }
        self.scratches = scratches
        let mode = grouping
        let folders = ScratchStore.folders()
        if isFoldersPane {
            if case .folder(let id) = filter, !folders.contains(where: { $0.id == id }) {
                Settings.shared.folderFilter = FolderFilter.allKey
            }
            if filter == .packages {
                roots = [Self.manifestNode()]
            } else if filter == .tools {
                roots = DevTools.all.map(Node.init(tool:))
            } else {
                roots = Self.leaves(scratches.filter(filter.includes), grouping: mode,
                                    keyPrefix: filter == .all ? "" : "\(filter.key)|")
            }
            folderPane.reload(scratches: scratches, folders: folders, filter: filter)
        } else {
            roots = Self.folderTree(scratches, folders: folders, in: "") { items, folder in
                Self.leaves(items, grouping: mode, keyPrefix: folder.isEmpty ? "" : folder + "|")
            } + [Self.devToolsFolder(), Self.sharedPackagesFolder()]
        }
        roots.forEach { $0.isTopLevel = true }
        suppressSelection = true
        outline.reloadData()
        let collapsed = Settings.shared.collapsedGroups
        func expand(_ nodes: [Node]) {
            for node in nodes where node.isExpandable {
                let holdsSelection = node.descendants.contains { $0.scratch.map(selected.contains) ?? false }
                if !collapsed.contains(node.groupKey!) || holdsSelection {
                    outline.expandItem(node)
                    expand(node.children)
                }
            }
        }
        expand(roots)
        let rows = IndexSet(selected.compactMap { s in
            let r = outline.row(forItem: node(for: s))
            return r >= 0 ? r : nil
        })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
        suppressSelection = false
        if let activeTool { selectTool(activeTool) }
    }

    /// Folders first (by name), then that folder's scratches (grouped by `leaves`); folders nest recursively.
    private static func folderTree(_ scratches: [Scratch], folders: [ScratchFolder], in parent: String,
                                   leaves: ([Scratch], String) -> [Node]) -> [Node] {
        let subfolders = folders.filter { $0.parent == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { Node(folder: $0, children: folderTree(scratches, folders: folders, in: $0.id, leaves: leaves)) }
        return subfolders + leaves(scratches.filter { $0.folder == parent }, parent)
    }

    /// One folder level's scratches: plain, or under type/date headers. Top-level header keys stay unprefixed
    /// so previously collapsed groups keep their state.
    private static func leaves(_ scratches: [Scratch], grouping: SidebarGrouping, keyPrefix: String) -> [Node] {
        switch grouping {
        case .none:
            return scratches.map(Node.init(scratch:))
        case .type:
            let byLanguage = Dictionary(grouping: scratches, by: \.language)
            return Language.allCases.compactMap { lang in
                guard let items = byLanguage[lang], !items.isEmpty else { return nil }
                return Node(key: keyPrefix + lang.rawValue, title: lang.displayName, children: items.map(Node.init(scratch:)))
            }
        case .date:
            let now = Date()
            let buckets = Dictionary(grouping: scratches.map { ($0, DateBucket.of($0.modified, now: now)) }, by: \.1.key)
            return buckets.values
                .sorted { $0[0].1.rank < $1[0].1.rank }
                .map { items in
                    let sorted = items.map(\.0).sorted { $0.modified > $1.modified }
                    return Node(key: keyPrefix + items[0].1.key, title: items[0].1.title, children: sorted.map(Node.init(scratch:)))
                }
        }
    }

    // MARK: Folders column

    /// Switches the file column to another folder (from a click in the folders column).
    fileprivate func setFilter(_ newFilter: FolderFilter) {
        guard newFilter != filter else { return }
        Settings.shared.folderFilter = newFilter.key
        let keep = highlighted.map { newFilter.includes($0) ? [$0] : [] } ?? []
        reload(scratches, selectAll: keep)
    }

    /// Brings a folder ("" for the top level) into view: opens it in the folders column, or expands and scrolls to it.
    func showFolder(_ id: String) {
        if isFoldersPane { return setFilter(id.isEmpty ? .all : .folder(id)) }
        guard !id.isEmpty, let item = node(forFolder: id) else { return outline.scrollRowToVisible(0) }
        expandAncestors(of: item)
        outline.expandItem(item)
        let row = outline.row(forItem: item)
        if row >= 0 { outline.scrollRowToVisible(row) }
    }

    @objc private func toggleFoldersPane() {
        delegate?.sidebar(self, perform: "toggleFoldersPane")
    }

    func setFoldersPane(_ on: Bool) {
        guard on != isFoldersPane else { return }
        Settings.shared.foldersPane = on
        foldersButton.state = on ? .on : .off
        if on {
            if let highlighted { Settings.shared.folderFilter = (highlighted.folder.isEmpty ? FolderFilter.unfiled : .folder(highlighted.folder)).key }
            installFolderPane()
        } else {
            folderPane.scroll.removeFromSuperview()
        }
        reload(scratches, selectAll: highlighted.map { [$0] } ?? [])
    }

    private func installFolderPane() {
        contentSplit.insertArrangedSubview(folderPane.scroll, at: 0)
        contentSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        contentSplit.setHoldingPriority(.init(250), forSubviewAt: 1)
        DispatchQueue.main.async { [self] in
            if folderPane.scroll.frame.width < 120 || folderPane.scroll.frame.width > contentSplit.bounds.width - 140 {
                contentSplit.setPosition(min(180, contentSplit.bounds.width * 0.45), ofDividerAt: 0)
            }
        }
    }

    /// Refreshes from disk while keeping the current selection.
    func refresh(_ scratches: [Scratch]) {
        let selected = selectedScratches.filter(scratches.contains)
        reload(scratches, selectAll: selected)
    }

    /// A single click on a header or folder row expands/collapses it (the disclosure triangle already does
    /// this itself, and ⌘/⇧-clicks are for multi-selection).
    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, node.isExpandable,
              let event = NSApp.currentEvent, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
        let point = outline.convert(event.locationInWindow, from: nil)
        if outline.frameOfOutlineCell(atRow: row).insetBy(dx: -4, dy: 0).contains(point) { return }
        toggle(node, in: outline)
    }

    fileprivate func toggle(_ item: Any, in outlineView: NSOutlineView) {
        if outlineView.isItemExpanded(item) { outlineView.animator().collapseItem(item) } else { outlineView.animator().expandItem(item) }
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let scratch = (outline.item(atRow: row) as? Node)?.scratch, scratch.isInScratchFolder else { return }
        beginRename(scratch)
    }

    /// Edits the scratch's name in place; Return renames, Escape or clicking away with no change cancels.
    func beginRename(_ scratch: Scratch) {
        guard let item = node(for: scratch) else { return }
        beginRename(item, currentName: scratch.name) { [weak self] name in
            guard let self else { return }
            self.delegate?.sidebar(self, rename: scratch, to: name)
        }
    }

    func beginRename(_ folder: ScratchFolder) {
        if isFoldersPane {
            folderPane.beginRename(folder) { [weak self] name in
                guard let self else { return }
                self.delegate?.sidebar(self, renameFolder: folder, to: name)
            }
            return
        }
        guard let item = node(forFolder: folder.id) else { return }
        beginRename(item, currentName: folder.name) { [weak self] name in
            guard let self else { return }
            self.delegate?.sidebar(self, renameFolder: folder, to: name)
        }
    }

    private func beginRename(_ item: Node, currentName: String, commit: @escaping (String) -> Void) {
        expandAncestors(of: item)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ScratchCell else { return }
        isRenaming = true
        isRenaming = cell.beginRename { [weak self] name in
            guard let self else { return }
            self.isRenaming = false
            let reload = self.pendingReload
            self.pendingReload = nil
            if let name, name != currentName {
                commit(name)
            } else {
                reload?()
            }
        }
    }

    private func expandAncestors(of item: Node) {
        var chain: [Any] = []
        var parent = outline.parent(forItem: item)
        while let p = parent {
            chain.insert(p, at: 0)
            parent = outline.parent(forItem: p)
        }
        chain.forEach { outline.expandItem($0) }
    }

    @objc private func revealCurrent() {
        delegate?.sidebar(self, perform: "revealInSidebar")
    }

    /// Selects the scratch (expanding its group if needed), scrolls it into the middle.
    func reveal(_ scratch: Scratch) {
        if isFoldersPane, !filter.includes(scratch) || node(for: scratch) == nil {
            reload(scratches, select: scratch)
        }
        highlighted = scratch
        guard let item = node(for: scratch) else { return }
        expandAncestors(of: item)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        suppressSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        suppressSelection = false
        if let clip = outline.enclosingScrollView?.contentView {
            let rect = outline.rect(ofRow: row)
            let y = max(0, min(rect.midY - clip.bounds.height / 2, outline.bounds.height - clip.bounds.height))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        }
        focus()
    }

    private func node(for scratch: Scratch) -> Node? {
        roots.lazy.flatMap { [$0] + $0.descendants }.first { $0.scratch == scratch }
    }

    private func node(forFolder id: String) -> Node? {
        roots.lazy.flatMap { [$0] + $0.descendants }.first { $0.folder?.id == id }
    }

    func focus() {
        view.window?.makeFirstResponder(outline)
    }

    // MARK: Grouping

    @objc private func showGroupingMenu() {
        groupingMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: groupButton.bounds.height + 4), in: groupButton)
    }

    private func groupingMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in SidebarGrouping.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(groupingChosen(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.target = self
            item.state = mode == grouping ? .on : .off
            item.image = NSImage(systemSymbolName: mode == .none ? "list.bullet" : mode == .type ? "doc.on.doc" : "calendar",
                                 accessibilityDescription: nil)
            menu.addItem(item)
            if mode == .none { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func groupingChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SidebarGrouping(rawValue: raw) else { return }
        setGrouping(mode)
    }

    /// Choosing the active mode again turns grouping off, so menu toggles behave as expected.
    func toggleGrouping(_ mode: SidebarGrouping) {
        setGrouping(grouping == mode ? .none : mode)
    }

    func setGrouping(_ mode: SidebarGrouping) {
        Settings.shared.sidebarGrouping = mode
        updateGroupButton()
        reload(scratches, selectAll: selectedScratches)
    }

    private func updateGroupButton() {
        groupButton.state = grouping == .none ? .off : .on
        groupButton.image = NSImage(systemSymbolName: grouping.symbol, accessibilityDescription: "Group Scratches")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        groupButton.toolTip = grouping == .none ? "Group Scratches" : "Grouping: \(grouping.title.replacingOccurrences(of: "Group by ", with: ""))"
    }

    // MARK: Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.isGroup && node.isTopLevel
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        let node = item as? Node
        return node?.scratch != nil || node?.tool != nil || node?.isFolder == true || node?.isSpecial == true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return 40 }
        return node.isGroup ? 26 : node.isFolder || node.isSpecial ? 32 : 40
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = HoverRowView()
        row.drawsRoundedSelection = false
        row.inset = 10
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if node.isGroup {
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: nil) as? GroupCell ?? GroupCell()
            cell.identifier = .init("group")
            cell.configure(node.groupTitle, count: node.children.count)
            return cell
        }
        if let folder = node.folder {
            let cell = outlineView.makeView(withIdentifier: .init("folder"), owner: nil) as? ScratchCell ?? ScratchCell()
            cell.identifier = .init("folder")
            cell.configure(folder: folder, count: node.scratchCount)
            return cell
        }
        if node.isSpecial {
            let cell = outlineView.makeView(withIdentifier: .init("folder"), owner: nil) as? ScratchCell ?? ScratchCell()
            cell.identifier = .init("folder")
            if node.groupKey == Self.toolsKey {
                cell.configure(special: node.groupTitle, symbol: "wrench.and.screwdriver.fill", tint: .systemIndigo, count: 0)
                cell.toolTip = "Encoders, decoders, hashes and other text tools"
            } else {
                cell.configure(special: node.groupTitle, symbol: "shippingbox.fill", tint: .systemRed, count: 1)
                cell.toolTip = "package.json shared by every JavaScript/TypeScript scratch"
            }
            return cell
        }
        if let tool = node.tool {
            let cell = outlineView.makeView(withIdentifier: .init("cell"), owner: nil) as? ScratchCell ?? ScratchCell()
            cell.identifier = .init("cell")
            cell.configure(tool: tool)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .init("cell"), owner: nil) as? ScratchCell ?? ScratchCell()
        cell.identifier = .init("cell")
        cell.configure(node.scratch!, showLanguage: grouping != .type, showFolder: isFoldersPane && filter == .all)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        if outline.selectedRowIndexes.count == 1, let tool = (outline.item(atRow: outline.selectedRow) as? Node)?.tool {
            delegate?.sidebar(self, openTool: tool.id)
            return
        }
        if outline.selectedRowIndexes.count == 1,
           (outline.item(atRow: outline.selectedRow) as? Node)?.scratch?.isSharedManifest == true {
            delegate?.sidebar(self, perform: "openSharedPackages")
            return
        }
        let selected = selectedScratches
        if selected.count == 1, selectedFolders.isEmpty {
            highlighted = selected[0]
            delegate?.sidebar(self, didSelect: selected[0])
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let key = (notification.userInfo?["NSObject"] as? Node)?.groupKey else { return }
        Settings.shared.collapsedGroups.insert(key)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let key = (notification.userInfo?["NSObject"] as? Node)?.groupKey else { return }
        Settings.shared.collapsedGroups.remove(key)
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        return (node.scratch?.url ?? node.folder?.url) as NSURL?
    }

    /// The folder a drop lands in: the folder row itself, a scratch row's folder, or the top level.
    /// nil when dropping into the Shared Packages folder, which only ever holds package.json.
    private func dropTarget(for item: Any?) -> (node: Node?, folder: String)? {
        var node = item as? Node
        while let n = node, n.folder == nil {
            if n.isSpecial || n.scratch?.isSharedManifest == true { return nil }
            node = outline.parent(forItem: n) as? Node
        }
        return (node, node?.folder?.id ?? "")
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = dropTarget(for: item) else { return [] }
        if info.draggingSource as? NSOutlineView === outline {
            let (scratches, folders) = draggedItems(info)
            let moves = scratches.contains { $0.folder != target.folder }
                || folders.contains { $0.parent != target.folder }
            let intoItself = folders.contains { $0.id == target.folder || $0.contains(target.folder) }
            guard moves, !intoItself else { return [] }
            outlineView.setDropItem(target.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard !externalFiles(info).isEmpty else { return [] }
        outlineView.setDropItem(target.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropTarget(for: item) else { return false }
        if info.draggingSource as? NSOutlineView === outline {
            let (scratches, folders) = draggedItems(info)
            guard !scratches.isEmpty || !folders.isEmpty else { return false }
            delegate?.sidebar(self, move: scratches, folders: folders, to: target.folder)
            return true
        }
        let urls = externalFiles(info)
        guard !urls.isEmpty else { return false }
        delegate?.sidebar(self, importFiles: urls, into: target.folder)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Scratches and folders dragged within the list. Folders' own contents are dropped from the set.
    fileprivate func draggedItems(_ info: NSDraggingInfo) -> ([Scratch], [ScratchFolder]) {
        var scratches: [Scratch] = [], folders: [ScratchFolder] = []
        for url in draggedURLs(info) {
            guard let id = relativePath(url), !id.isEmpty else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(ScratchFolder(id: id)) } else { scratches.append(Scratch(url: url)) }
        }
        let nested = { (id: String) in folders.contains { $0.contains(id) } }
        return (scratches.filter { !nested($0.id) }, folders.filter { !nested($0.id) })
    }

    /// Regular files from outside the scratch folder (Finder, other apps).
    fileprivate func externalFiles(_ info: NSDraggingInfo) -> [URL] {
        draggedURLs(info).filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
                && relativePath(url) == nil
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard let delegate else { return }
        let node = row >= 0 ? outline.item(atRow: row) as? Node : nil
        if let tool = node?.tool {
            menu.addItem(ClosureMenuItem(title: "Open \(tool.title)") { [weak self] in
                guard let self else { return }
                self.delegate?.sidebar(self, openTool: tool.id)
            })
            return
        }
        if node?.groupKey == Self.toolsKey { return }
        if node?.isSpecial == true || node?.scratch?.isSharedManifest == true {
            for (title, id) in [("Open package.json", "openSharedPackages"), ("npm install", "installSharedPackages")] {
                menu.addItem(ClosureMenuItem(title: title) { [weak self] in
                    guard let self else { return }
                    self.delegate?.sidebar(self, perform: id)
                })
            }
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([SharedPackages.manifest])
            })
            return
        }
        if node?.scratch == nil, node?.isGroup != true {
            if row >= 0, !outline.selectedRowIndexes.contains(row) { outline.selectRowIndexes([row], byExtendingSelection: false) }
            if row < 0 { outline.deselectAll(nil) }
            for item in delegate.sidebarFolderMenu(self, for: node?.folder).items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
            return
        }
        guard let node, let scratch = node.scratch else { return }
        if !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        let selected = selectedScratches.isEmpty ? [scratch] : selectedScratches
        for item in delegate.sidebarContextMenu(self, for: selected).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// Routes sidebar-scoped shortcuts (⌘C, ⌘D, ⌘⌫, Return…) before the menu bar sees them.
private final class SidebarOutlineView: NSOutlineView {
    var onShortcut: ((KeyCombo) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let combo = KeyCombo(event: event), onShortcut?(combo) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let combo = KeyCombo(event: event), onShortcut?(combo) == true { return }
        super.keyDown(with: event)
    }
}

private final class GroupCell: NSTableCellView {
    private let label = NSTextField.label("", size: 11, weight: .semibold)
    private let count = NSTextField.label("", size: 10, weight: .semibold)
    private let badge = NSView()

    init() {
        super.init(frame: .zero)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        count.alignment = .center
        count.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(count)
        let row = NSStackView(views: [label, badge])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        textField = label
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            count.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
            count.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
            count.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String, count n: Int) {
        label.stringValue = title.uppercased()
        count.stringValue = "\(n)"
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

private final class ScratchCell: NSTableCellView {
    private let icon = SymbolTile(side: 24)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            icon.isOnSelection = backgroundStyle == .emphasized
            if isRenaming { title.textColor = .labelColor }
        }
    }

    // MARK: Inline rename

    private var isRenaming = false
    private var isFolder = false
    private var renameCancelled = false
    private var onRenameEnd: ((String?) -> Void)?
    private var renameWidth: NSLayoutConstraint?

    /// Returns false when editing couldn't start (the cell isn't on screen or is already editing).
    func beginRename(onEnd: @escaping (String?) -> Void) -> Bool {
        guard !isRenaming, let window else { return false }
        isRenaming = true
        renameCancelled = false
        onRenameEnd = onEnd
        title.isEditable = true
        title.isSelectable = true
        (superview as? HoverRowView)?.isQuiet = true
        title.isBezeled = false
        title.drawsBackground = true
        title.backgroundColor = .textBackgroundColor
        title.textColor = .labelColor
        title.focusRingType = .none
        title.wantsLayer = true
        title.layer?.cornerRadius = 4
        title.layer?.cornerCurve = .continuous
        title.layer?.borderWidth = 1
        title.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        title.lineBreakMode = .byClipping
        title.delegate = self
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        renameWidth = title.widthAnchor.constraint(greaterThanOrEqualToConstant: max(120, bounds.width - 44))
        renameWidth?.isActive = true
        window.makeFirstResponder(title)
        let stem = isFolder ? title.stringValue : (title.stringValue as NSString).deletingPathExtension
        title.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        return true
    }

    private func endRename() {
        guard isRenaming else { return }
        isRenaming = false
        (superview as? HoverRowView)?.isQuiet = false
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        title.layer?.borderWidth = 0
        title.lineBreakMode = .byTruncatingMiddle
        renameWidth?.isActive = false
        renameWidth = nil
        title.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let name = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onRenameEnd
        onRenameEnd = nil
        if renameCancelled || name.isEmpty { title.stringValue = original ?? title.stringValue }
        callback?(renameCancelled || name.isEmpty ? nil : name)
    }

    private var original: String?

    fileprivate func renameCancelledByUser() {
        renameCancelled = true
        window?.makeFirstResponder(enclosingScrollView?.documentView)
    }

    fileprivate func endRenameFromEditing() {
        endRename()
    }

    func configure(special title: String, symbol: String, tint: NSColor, count: Int) {
        isFolder = true
        original = title
        self.title.stringValue = title
        icon.configure(symbol: symbol, tint: tint)
        subtitle.isHidden = true
        toolTip = count == 1 ? "1 scratch" : "\(count) scratches"
    }

    func configure(tool: DevTool) {
        isFolder = false
        original = tool.title
        title.stringValue = tool.title
        icon.configure(symbol: tool.symbol, tint: tool.tint)
        subtitle.stringValue = tool.summary
        subtitle.isHidden = false
        toolTip = tool.summary
    }

    func configure(folder: ScratchFolder, count: Int) {
        isFolder = true
        original = folder.name
        title.stringValue = folder.name
        icon.configure(symbol: "folder.fill", tint: .systemBlue)
        subtitle.stringValue = count == 1 ? "1 scratch" : "\(count) scratches"
        subtitle.isHidden = true
        toolTip = "\(folder.url.path)\n\(subtitle.stringValue)"
    }

    func configure(_ scratch: Scratch, showLanguage: Bool, showFolder: Bool = false) {
        isFolder = false
        subtitle.isHidden = false
        original = scratch.name
        title.stringValue = scratch.name
        icon.configure(scratch.language)
        let age = Date().timeIntervalSince(scratch.modified)
        let edited = age < 60 ? "just now" : Self.relative.localizedString(for: scratch.modified, relativeTo: Date())
        var parts = [String]()
        if showFolder, !scratch.folder.isEmpty { parts.append(scratch.folder) }
        if showLanguage { parts.append(scratch.language.displayName) }
        parts.append("edited \(edited)")
        subtitle.stringValue = parts.joined(separator: " · ")
        toolTip = "\(scratch.url.path)\nCreated \(Self.absolute.string(from: scratch.created))\nModified \(Self.absolute.string(from: scratch.modified))"
    }
}

extension ScratchCell: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelledByUser()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRenameFromEditing()
    }
}

// MARK: - Folders column

private final class PaneNode: NSObject {
    let filter: FolderFilter
    let folder: ScratchFolder?
    var children: [PaneNode] = []

    init(filter: FolderFilter, folder: ScratchFolder? = nil, children: [PaneNode] = []) {
        self.filter = filter
        self.folder = folder
        self.children = children
    }

    var descendants: [PaneNode] { children.flatMap { [$0] + $0.descendants } }
}

/// Left column of the two-column sidebar: "All Scratches", "Unfiled" and the folder tree.
/// Picking a row filters the scratch column; scratches can be dropped onto folders to move them.
private final class FolderPaneController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    unowned let sidebar: SidebarViewController
    let outline = NSOutlineView()
    let scroll = NSScrollView()
    private var roots: [PaneNode] = []
    private var counts: [String: Int] = [:]
    private var total = 0
    private var suppressSelection = false

    init(sidebar: SidebarViewController) {
        self.sidebar = sidebar
        super.init()
        let column = NSTableColumn(identifier: .init("folder"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 30
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 10
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
    }

    func reload(scratches: [Scratch], folders: [ScratchFolder], filter: FolderFilter) {
        total = scratches.count
        counts = Dictionary(grouping: scratches, by: \.folder).mapValues(\.count)
        func tree(_ parent: String) -> [PaneNode] {
            folders.filter { $0.parent == parent }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { PaneNode(filter: .folder($0.id), folder: $0, children: tree($0.id)) }
        }
        roots = [PaneNode(filter: .all), PaneNode(filter: .unfiled)] + tree("") + [PaneNode(filter: .tools), PaneNode(filter: .packages)]
        suppressSelection = true
        outline.reloadData()
        let collapsed = Settings.shared.collapsedGroups
        func expand(_ nodes: [PaneNode]) {
            for node in nodes where !node.children.isEmpty {
                let holdsFilter = node.descendants.contains { $0.filter == filter }
                if !collapsed.contains(key(node)) || holdsFilter {
                    outline.expandItem(node)
                    expand(node.children)
                }
            }
        }
        expand(roots)
        if let node = roots.flatMap({ [$0] + $0.descendants }).first(where: { $0.filter == filter }) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
        suppressSelection = false
    }

    private func key(_ node: PaneNode) -> String { "pane:\(node.filter.key)" }

    private func node(forFolder id: String) -> PaneNode? {
        roots.flatMap { [$0] + $0.descendants }.first { $0.folder?.id == id }
    }

    /// Scratch count for a row, including nested folders.
    private func count(_ node: PaneNode) -> Int {
        switch node.filter {
        case .all: return total
        case .unfiled: return counts[""] ?? 0
        case .packages: return 1
        case .tools: return DevTools.all.count
        case .folder(let id): return counts.filter { $0.key == id || $0.key.hasPrefix(id + "/") }.values.reduce(0, +)
        }
    }

    func beginRename(_ folder: ScratchFolder, commit: @escaping (String) -> Void) {
        guard let item = node(forFolder: folder.id) else { return }
        var parent = outline.parent(forItem: item)
        var chain: [Any] = []
        while let p = parent { chain.insert(p, at: 0); parent = outline.parent(forItem: p) }
        chain.forEach { outline.expandItem($0) }
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ScratchCell else { return }
        outline.scrollRowToVisible(row)
        sidebar.isRenaming = true
        sidebar.isRenaming = cell.beginRename { [weak self] name in
            guard let self else { return }
            self.sidebar.isRenaming = false
            let reload = self.sidebar.pendingReload
            self.sidebar.pendingReload = nil
            if let name, name != folder.name { commit(name) } else { reload?() }
        }
    }

    private var justSelected = false

    /// The first click on a folder selects it; clicking the already-selected folder expands/collapses it.
    @objc private func clicked() {
        defer { justSelected = false }
        let row = outline.clickedRow
        guard !justSelected, row >= 0, let node = outline.item(atRow: row) as? PaneNode, !node.children.isEmpty,
              let event = NSApp.currentEvent, event.clickCount == 1 else { return }
        let point = outline.convert(event.locationInWindow, from: nil)
        if outline.frameOfOutlineCell(atRow: row).insetBy(dx: -4, dy: 0).contains(point) { return }
        sidebar.toggle(node, in: outline)
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let folder = (outline.item(atRow: row) as? PaneNode)?.folder else { return }
        sidebar.beginRename(folder)
    }

    // MARK: Data source & delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? PaneNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? PaneNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? PaneNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 30 }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = HoverRowView()
        row.drawsRoundedSelection = false
        row.inset = 10
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PaneNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("pane"), owner: nil) as? ScratchCell ?? ScratchCell()
        cell.identifier = .init("pane")
        switch node.filter {
        case .all: cell.configure(special: "All Scratches", symbol: "tray.full.fill", tint: .systemGray, count: count(node))
        case .unfiled: cell.configure(special: "Unfiled", symbol: "tray.fill", tint: .systemTeal, count: count(node))
        case .tools:
            cell.configure(special: "Dev Tools", symbol: "wrench.and.screwdriver.fill", tint: .systemIndigo, count: count(node))
            cell.toolTip = "Encoders, decoders, hashes and other text tools"
        case .packages:
            cell.configure(special: "Shared Packages", symbol: "shippingbox.fill", tint: .systemRed, count: 1)
            cell.toolTip = "package.json shared by every JavaScript/TypeScript scratch"
        case .folder: cell.configure(folder: node.folder!, count: count(node))
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = outline.item(atRow: outline.selectedRow) as? PaneNode else { return }
        justSelected = true
        if node.filter == .packages { sidebar.delegate?.sidebar(sidebar, perform: "openSharedPackages") }
        sidebar.setFilter(node.filter)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? PaneNode else { return }
        Settings.shared.collapsedGroups.insert(key(node))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? PaneNode else { return }
        Settings.shared.collapsedGroups.remove(key(node))
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? PaneNode)?.folder?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? PaneNode, let target = node.filter.folderId else { return [] }
        let source = info.draggingSource as? NSOutlineView
        if source === outline || source === sidebar.outline {
            let (scratches, folders) = sidebar.draggedItems(info)
            let moves = scratches.contains { $0.folder != target } || folders.contains { $0.parent != target }
            let intoItself = folders.contains { $0.id == target || $0.contains(target) }
            guard moves, !intoItself else { return [] }
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard !sidebar.externalFiles(info).isEmpty else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = (item as? PaneNode)?.filter.folderId, let delegate = sidebar.delegate else { return false }
        let source = info.draggingSource as? NSOutlineView
        if source === outline || source === sidebar.outline {
            let (scratches, folders) = sidebar.draggedItems(info)
            guard !scratches.isEmpty || !folders.isEmpty else { return false }
            delegate.sidebar(sidebar, move: scratches, folders: folders, to: target)
            return true
        }
        let urls = sidebar.externalFiles(info)
        guard !urls.isEmpty else { return false }
        delegate.sidebar(sidebar, importFiles: urls, into: target)
        return true
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let delegate = sidebar.delegate else { return }
        let row = outline.clickedRow
        let node = row >= 0 ? outline.item(atRow: row) as? PaneNode : nil
        if node != nil, row != outline.selectedRow {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        let source: NSMenu
        if let folder = node?.folder {
            source = delegate.sidebarFolderMenu(sidebar, for: folder)
        } else {
            source = delegate.sidebarFolderMenu(sidebar, for: nil)
        }
        for item in source.items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}
