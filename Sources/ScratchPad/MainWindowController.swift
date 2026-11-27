import AppKit

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = Self("sidebarToggle")
    static let title = Self("title")
    static let tabs = Self("tabs")
    static let codeGroup = Self("codeGroup")
    static let fileGroup = Self("fileGroup")
    static let toolsGroup = Self("toolsGroup")
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let store = ScratchStore()
    private let editor = EditorController()
    private let runner = Runner()
    private let http = HTTPClient()

    private let sidebar = SidebarViewController()
    private let console = ConsoleViewController()
    private let editorPane = EditorPaneViewController()
    private let outerSplit = NSSplitViewController()
    private let innerSplit = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var consoleItem: NSSplitViewItem!
    private let languageButton = ToolbarMenuButton(compact: true)
    private let jdkButton = ToolbarMenuButton(compact: true)
    private let viewerButton = ToolbarMenuButton(compact: true)
    private lazy var exportButton = ToolbarStyle.makeCompact(ToolbarStyle.button(
        symbol: "square.and.arrow.up", tip: "Export…", target: self, action: #selector(exportButtonClicked(_:))))
    /// Files in the order they were opened (ids, oldest first), and the position of the open one; Back and
    /// Forward move the position, opening anything new drops the entries after it.
    private var history: [String] = []
    private var historyIndex = -1
    private var toolbarButtons: [String: HoverButton] = [:]
    private var previewButtons: [HoverButton] = []
    private lazy var previewGroup = ToolbarGroup(previewButtons.map(ToolbarStyle.makeCompact), compact: true)
    private lazy var packagesGroup = ToolbarGroup(["openSharedPackages", "installSharedPackages"].compactMap { toolbarButtons[$0] }
        .map(ToolbarStyle.makeCompact), compact: true)
    private let titleField = TitleField()

    private(set) var current: Scratch?
    private let tabBar = TabBarView()
    static let tabBarHeight: CGFloat = 38
    /// Files open as tabs, in tab order.
    private var tabs: [Scratch] = [] {
        didSet { if tabs != oldValue { Settings.shared.openTabs = tabs.map(\.id) } }
    }
    private lazy var emptyPage = EmptyEditorPage { [weak self] id in self?.perform(id) }
    private var messageTimer: Timer?
    private var isDiffing = false
    private let toolPage = DevToolViewController()
    /// The native page for rich text scratches, shown in place of the code editor.
    private let richPage = RichTextViewController()
    /// Documents from outside the scratch folder opened this session, by id, so late saves still find them.
    private var externalById: [String: Scratch] = [:]
    /// Scratches created (or switched) to Plain Text on purpose, which keep their type when you paste into them.
    private var explicitPlainText: Set<String> = []
    private lazy var gotoPicker = CommandPaletteController(
        title: "Go to Scratch", placeholder: "Scratch name — fuzzy: “apcl” finds api-client.http · folder/name · name:line",
        empty: "No matching scratches", noun: ("match", "matches"), verb: "Open", usesRecents: false)
    /// The dev tool page showing in place of the editor, if any.
    private var activeTool: DevTool?
    private var previewBeforeFull: PreviewMode = .split
    private var httpRun: (scratchId: String, requests: [HTTPRequest])?
    private lazy var findInScratches: FindInScratchesController = {
        let controller = FindInScratchesController()
        controller.delegate = self
        return controller
    }()
    private lazy var palette = CommandPaletteController()
    private lazy var newScratchPicker = CommandPaletteController(
        title: "New Scratch", placeholder: "File type — type to filter", empty: "No matching file types",
        noun: ("file type", "file types"), verb: "Create", usesRecents: false)
    private lazy var symbolPicker = CommandPaletteController(
        title: "Go to Symbol", placeholder: "", empty: "No matching symbols", noun: ("symbol", "symbols"),
        verb: "Go", usesRecents: false, height: 640)
    private lazy var recentPicker = CommandPaletteController(
        title: "Recent Scratches", placeholder: "Recent scratches — type to filter", empty: "No matching scratches",
        noun: ("scratch", "scratches"), verb: "Open", usesRecents: false)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "ScratchPad"
        window.titleVisibility = .hidden
        // The editor pane paints the tab strip's backdrop under the toolbar itself (see `TabBackdropView`).
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 620, height: 320)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        editor.delegate = self
        runner.delegate = self
        console.onClose = { [weak self] in self?.showConsole(false) }
        console.onTogglePosition = { [weak self] in self?.toggleConsolePosition() }
        editorPane.onPositionClick = { [weak self] in self?.editor.exec("gotoLine") }
        editorPane.onLanguageClick = { [weak self] button in self?.showLanguageMenu(from: button) }
        editorPane.onPathClick = { [weak self] index, view in self?.showPathMenu(index, from: view) }
        http.onResult = { [weak self] index, result in self?.reportHTTPResult(index, result) }
        http.onFinish = { [weak self] cancelled in
            guard let self else { return }
            if let run = self.httpRun { self.editor.httpFinished(scratchId: run.scratchId, cancelled: cancelled) }
            self.updateToolbarState()
        }
        sidebar.delegate = self
        editorPane.webView = editor.webView
        editorPane.tabStrip = tabBar
        tabBar.onRename = { [weak self] id in
            guard let self else { return }
            if id == self.current?.id { return self.beginRename() }
            self.activateTab(id)
            DispatchQueue.main.async { if self.current?.id == id { self.beginRename() } }
        }
        tabBar.onSelect = { [weak self] id in self?.activateTab(id) }
        tabBar.onClose = { [weak self] id in self?.closeTabs { $0.id == id } }
        tabBar.onReorder = { [weak self] ids in
            guard let self else { return }
            let byId = Dictionary(self.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.tabs = ids.compactMap { byId[$0] }
        }
        tabBar.onMenu = { [weak self] id in self?.tabMenu(for: id) }
        tabBar.onNew = { [weak self] in self?.perform("newScratch") }
        titleField.onRename = { [weak self] name in self?.renameCurrent(to: name) }

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = Settings.shared.foldersPane ? 720 : 420
        sidebarItem.canCollapse = true

        let isConsoleRight = Settings.shared.consolePosition == .right
        innerSplit.splitView.isVertical = isConsoleRight
        innerSplit.splitView.dividerStyle = .thin
        let editorItem = NSSplitViewItem(viewController: editorPane)
        editorItem.holdingPriority = .defaultLow
        consoleItem = NSSplitViewItem(viewController: console)
        consoleItem.canCollapse = true
        consoleItem.minimumThickness = isConsoleRight ? 180 : 120
        consoleItem.holdingPriority = .init(260)
        innerSplit.addSplitViewItem(editorItem)
        innerSplit.addSplitViewItem(consoleItem)
        consoleItem.isCollapsed = true

        outerSplit.addSplitViewItem(sidebarItem)
        let contentItem = NSSplitViewItem(viewController: innerSplit)
        // No line under the toolbar here, so the active tab runs straight into the page below it.
        contentItem.titlebarSeparatorStyle = .none
        outerSplit.addSplitViewItem(contentItem)
        outerSplit.splitView.autosaveName = "ScratchPad.outerSplit"
        window.contentViewController = outerSplit

        setUpToolbar()
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("ScratchPad.MainWindow")

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keymapChanged), name: .keymapChanged, object: nil)

        richPage.onChange = { [weak self] text in
            guard let self, let scratch = self.richPage.scratch else { return }
            self.store.saveRich(scratch, text: text)
        }
        loadInitialScratch()
        toolPage.onOpenInScratch = { [weak self] text in
            guard let self, let scratch = self.createScratch(.text, content: text) else { return }
            self.sidebar.reload(self.store.list(), select: scratch)
        }
        if let id = Settings.shared.lastTool { openTool(id) }
        editor.setPreview(Settings.shared.previewMode)
        store.watch { [weak self] in self?.scratchFolderChanged() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Scratch lifecycle

    private func loadInitialScratch() {
        var all = store.list()
        if all.isEmpty, let created = try? store.create(language: .text) {
            all = [created]
        }
        tabs = Settings.shared.openTabs.compactMap(scratch(forId:))
        let last = tabs.first { $0.id == Settings.shared.lastScratch }
            ?? all.first { $0.id == Settings.shared.lastScratch } ?? tabs.first ?? all.first
        sidebar.reload(all, select: last?.isListed == true ? last : nil)
        if let last { open(last) }
    }

    private func refreshList(select: Scratch?) {
        sidebar.reload(store.list(), select: select)
    }

    /// Files were added, removed or renamed in the scratch folder (possibly outside the app).
    private func scratchFolderChanged() {
        let all = store.list()
        sidebar.refresh(all)
        // Files deleted or renamed elsewhere lose their tabs; the open one hands over to a neighbouring tab.
        let listed = Set(all)
        dropTabs { $0.isListed ? !listed.contains($0) : !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    // MARK: Tabs

    /// The file an id names (a path relative to the scratches folder, or an absolute path), if it exists.
    private func scratch(forId id: String) -> Scratch? {
        // Files from elsewhere aren't checked until opened (open() reports missing ones): see Scratch(url:readAttributes:).
        if id.hasPrefix("/") { return Scratch(url: URL(fileURLWithPath: id), readAttributes: false) }
        let url = AppPaths.scratches.appendingPathComponent(id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return Scratch(url: url)
    }

    private func refreshTabs() {
        let names = Dictionary(grouping: tabs, by: \.name)
        tabBar.setTabs(tabs.map { tab in
            // Same-named files from different folders get their folder name added.
            let folder = tab.url.deletingLastPathComponent().lastPathComponent
            let title = (names[tab.name]?.count ?? 0) > 1 ? "\(tab.name) — \(folder)" : tab.name
            let tip = tab.isInScratchFolder ? "Scratches/\(tab.id)" : ExternalFolders.displayPath(tab.url.path)
            return TabBarView.Tab(id: tab.id, title: title, symbol: tab.language.symbolName, tint: tab.language.tint, tip: tip)
        }, active: activeTool == nil ? current?.id : nil)
    }

    private func activateTab(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab == current, activeTool == nil { return focusEditor() }
        editor.flush { [self] in
            sidebar.reload(store.list(), select: tab.isListed ? tab : nil)
            open(tab)
            focusEditor()
        }
    }

    private func stepTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let index = current.flatMap { tabs.firstIndex(of: $0) } ?? -delta
        activateTab(tabs[(index + delta + tabs.count) % tabs.count].id)
    }

    /// Closes the matching tabs, saving first; closing the open file moves to the tab after it (else before it).
    private func closeTabs(where shouldClose: @escaping (Scratch) -> Bool) {
        guard tabs.contains(where: shouldClose) else { return }
        editor.flush { [self] in
            store.flushWrites()
            dropTabs(where: shouldClose)
        }
    }

    /// Removes tabs without saving (their files are already saved or gone) and picks what to show instead.
    private func dropTabs(where shouldDrop: (Scratch) -> Bool) {
        let closing = tabs.filter(shouldDrop)
        guard !closing.isEmpty || current.map(shouldDrop) == true else { return }
        var next: Scratch?
        if let current, shouldDrop(current) {
            let index = tabs.firstIndex(of: current) ?? tabs.count
            next = tabs[min(index, tabs.count)...].first { !shouldDrop($0) } ?? tabs[..<min(index, tabs.count)].last { !shouldDrop($0) }
        }
        let closingCurrent = current.map(shouldDrop) == true
        tabs.removeAll(where: shouldDrop)
        for tab in closing where tab != current { editor.forget(id: tab.id) }
        guard closingCurrent, let current else { return refreshTabs() }
        if let next {
            sidebar.reload(store.list(), select: next.isListed ? next : nil)
            open(next)
            if activeTool == nil { focusEditor() }
        } else {
            showEmptyState()
        }
        editor.forget(id: current.id)
    }

    /// No tabs left: a placeholder with New / Go to instead of the editor.
    private func showEmptyState() {
        current = nil
        isDiffing = false
        sidebar.reload(store.list(), select: nil)
        if activeTool == nil {
            editorPane.showPage(emptyPage)
            window?.makeFirstResponder(emptyPage)
        }
        updateChrome()
    }

    private func tabMenu(for id: String?) -> NSMenu? {
        guard let id else {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "New Scratch") { [weak self] in self?.perform("newScratch") })
            let closeAll = ClosureMenuItem(title: "Close All Tabs") { [weak self] in self?.closeTabs { _ in true } }
            closeAll.isEnabled = !tabs.isEmpty
            menu.autoenablesItems = false
            menu.addItem(closeAll)
            return menu
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs[index]
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String?, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: run)
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        let ids = tabs.map(\.id)
        add("Close", "xmark") { [weak self] in self?.closeTabs { $0.id == id } }
        add("Close Others", nil, enabled: tabs.count > 1) { [weak self] in self?.closeTabs { $0.id != id } }
        add("Close Tabs to the Left", "arrow.left.to.line", enabled: index > 0) { [weak self] in
            self?.closeTabs { (ids.firstIndex(of: $0.id) ?? .max) < index }
        }
        add("Close Tabs to the Right", "arrow.right.to.line", enabled: index < tabs.count - 1) { [weak self] in
            self?.closeTabs { (ids.firstIndex(of: $0.id) ?? -1) > index }
        }
        add("Close All", nil) { [weak self] in self?.closeTabs { _ in true } }
        menu.addItem(.separator())
        add("Copy Path", "doc.on.doc") { [weak self] in self?.copyPath([tab]) }
        add("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([tab.url]) }
        if tab.isListed {
            add("Reveal in Sidebar", "sidebar.left") { [weak self] in
                guard let self else { return }
                if self.sidebarItem.isCollapsed { self.sidebarItem.animator().isCollapsed = false }
                self.sidebar.reveal(tab)
            }
        }
        return menu
    }

    /// ⌘S: everything is saved as you type, but this writes pending edits right away and says so.
    private func saveNow() {
        guard let scratch = current, activeTool == nil else { return NSSound.beep() }
        let finish = { [self] in
            store.flushWrites()
            showMessage("Saved \(scratch.name)")
        }
        if showsRichText { finish() } else { editor.flush { DispatchQueue.main.async(execute: finish) } }
    }

    private func open(_ scratch: Scratch, initialText: String? = nil, recordHistory: Bool = true) {
        if !scratch.isInScratchFolder, !scratch.isSharedManifest, let reason = Self.unopenableReason(scratch.url) {
            if reason == "not found" {
                Settings.shared.openedFiles.removeAll { $0 == scratch.url.path }
                tabs.removeAll { $0 == scratch }
                refreshTabs()
            }
            Toast.show("Can't open \(scratch.name): \(reason)", symbol: "exclamationmark.triangle.fill",
                       tint: .systemOrange, in: window)
            if let current { sidebar.reload(store.list(), select: current.isListed ? current : nil) }
            return
        }
        if activeTool != nil { closeTool() }
        if recordHistory { recordVisit(scratch) }
        if !tabs.contains(scratch) {
            let index = current.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
            tabs.insert(scratch, at: index)
        }
        current = scratch
        isDiffing = false
        if scratch.isListed {
            Settings.shared.lastScratch = scratch.id
            Settings.shared.recentScratches = [scratch.id] + Settings.shared.recentScratches.filter { $0 != scratch.id }
        }
        if !scratch.isInScratchFolder { externalById[scratch.id] = scratch }
        if scratch.language.isRichText {
            editor.flush {}
            let rich = initialText.map { RichTextIO.plain($0) } ?? store.readRich(scratch)
            richPage.load(scratch, text: rich)
            editorPane.showPage(richPage.view)
        } else {
            editorPane.showPage(nil)
            let text = initialText ?? store.read(scratch)
            editor.load(id: scratch.id, text: text, language: scratch.language)
        }
        updateChrome()
    }

    /// True while a rich text scratch (not a dev tool) fills the editor area.
    private var showsRichText: Bool { activeTool == nil && current?.language.isRichText == true }

    private var layoutBeforeEditorOnly: (sidebar: Bool, console: Bool)?

    private func focusEditor() {
        window?.makeKeyAndOrderFront(nil)
        if showsRichText {
            richPage.focus()
        } else {
            if let window { window.makeFirstResponder(editor.webView) }
            editor.focus()
        }
    }

    // MARK: Dev tools

    private func openTool(_ id: String) {
        guard let tool = DevTools.byId[id] else { return }
        activeTool = tool
        Settings.shared.lastTool = id
        toolPage.load(tool)
        editorPane.showPage(toolPage.view)
        sidebar.setActiveTool(id)
        updateChrome()
        toolPage.focusInput()
    }

    private func closeTool() {
        activeTool = nil
        Settings.shared.lastTool = nil
        editorPane.showPage(current == nil ? emptyPage : showsRichText ? richPage.view : nil)
        sidebar.setActiveTool(nil)
    }

    private func toolsMenu() -> NSMenu {
        let menu = NSMenu()
        let show = ClosureMenuItem(title: "Show in Sidebar") { [weak self] in
            guard let self, let tool = self.activeTool else { return }
            if self.sidebarItem.isCollapsed { self.sidebarItem.animator().isCollapsed = false }
            self.sidebar.setActiveTool(tool.id)
        }
        show.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        menu.addItem(show)
        menu.addItem(.separator())
        for tool in DevTools.all {
            let item = ClosureMenuItem(title: tool.title) { [weak self] in self?.openTool(tool.id) }
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [tool.tint]))
            item.state = tool.id == activeTool?.id ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func updateChrome() {
        refreshTabs()
        titleField.isRenamable = activeTool == nil && current != nil
        if let tool = activeTool {
            window?.title = tool.title
            titleField.show(tool.title)
            titleField.toolTip = tool.summary
            editorPane.setPath(["Dev Tools"], name: tool.title)
            for control in [languageButton, previewGroup, viewerButton, exportButton, jdkButton, packagesGroup] as [NSView] { control.isHidden = true }
            updateToolbarState()
            return
        }
        guard let current else {
            window?.title = "ScratchPad"
            titleField.show("ScratchPad")
            titleField.toolTip = nil
            editorPane.setPath([], name: "")
            for control in [languageButton, previewGroup, viewerButton, exportButton, jdkButton, packagesGroup] as [NSView] { control.isHidden = true }
            updateToolbarState()
            return
        }
        languageButton.isHidden = false
        window?.title = current.name
        titleField.show(current.name)
        titleField.toolTip = current.isListed ? "\(current.url.path)\nDouble-click to rename" : current.url.path
        languageButton.show(current.language)
        editorPane.setLanguage(current.language)
        updatePreviewControl()
        jdkButton.isHidden = current.language != .java
        packagesGroup.isHidden = ![.javascript, .typescript].contains(current.language) && !current.isSharedManifest
        let location = current.isSharedManifest ? ["Shared Packages"]
            : current.isListed ? breadcrumb(for: current).map(\.title)
            : [ExternalFolders.displayPath(current.url.deletingLastPathComponent().path)]
        editorPane.setPath(location, name: current.name)
        sidebar.setSharedPackagesActive(current.isSharedManifest)
        if current.language == .java { updateJDKButton() }
        updateToolbarState()
    }

    /// The folders above a listed file, each with the folder id its breadcrumb opens.
    private func breadcrumb(for scratch: Scratch) -> [(title: String, id: String)] {
        var crumbs: [(title: String, id: String)]
        var id: String
        var rest: Substring
        if scratch.isInScratchFolder {
            crumbs = [("Scratches", "")]
            id = ""
            rest = Substring(scratch.folder)
        } else if let root = scratch.externalRoot {
            crumbs = [((root as NSString).lastPathComponent, root)]
            id = root
            rest = scratch.folder.dropFirst(root.count)
        } else {
            return []
        }
        for part in rest.split(separator: "/") {
            id = id.isEmpty ? String(part) : id + "/" + part
            crumbs.append((String(part), id))
        }
        return crumbs
    }

    private static var javaTemplate: String {
        let indent = String(repeating: " ", count: Settings.shared.tabSize)
        return "public class Main {\n\(indent)public static void main(String[] args) {\n\(indent)\(indent)System.out.println(\"Hello\");\n\(indent)}\n}\n"
    }

    /// Folder for new scratches: what's selected in the list, else the open scratch's folder.
    private var newScratchFolder: String {
        sidebar.targetFolder ?? (current?.isListed == true ? current!.folder : "")
    }

    @discardableResult
    private func createScratch(_ language: Language, content: String = "", in folder: String? = nil) -> Scratch? {
        do {
            let initial = !content.isEmpty ? content : language == .http ? HTTPFile.template
                : language == .diff ? DiffFile.template : language == .java ? Self.javaTemplate : content
            let scratch = try store.create(language: language, content: initial, in: folder ?? newScratchFolder)
            if language != .text { Settings.shared.lastLanguage = language }
            open(scratch, initialText: initial)
            focusEditor()
            DispatchQueue.main.async { [weak self] in
                self?.refreshList(select: scratch)
                self?.focusEditor()
            }
            return scratch
        } catch {
            presentError(error)
            return nil
        }
    }

    private func replaceCurrent(with updated: Scratch, from old: Scratch) {
        editor.rename(from: old.id, to: updated.id)
        if richPage.scratch == old { richPage.retarget(updated) }
        if explicitPlainText.remove(old.id) != nil, updated.language == .text { explicitPlainText.insert(updated.id) }
        current = updated
        tabs = tabs.map { $0 == old ? updated : $0 }
        Settings.shared.lastScratch = updated.id
        Settings.shared.recentScratches = Settings.shared.recentScratches.map { $0 == old.id ? updated.id : $0 }
        remapHistory { $0 == old.id ? updated.id : nil }
        refreshList(select: updated)
        updateChrome()
    }

    private func changeLanguage(to language: Language) {
        guard let scratch = current, scratch.language != language else { return }
        editor.flush { [self] in
            do {
                let updated = try store.changeLanguage(scratch, to: language)
                replaceCurrent(with: updated, from: scratch)
                if scratch.language.isRichText || language.isRichText {
                    // The content was converted on disk; reload it in the other kind of editor.
                    editor.forget(id: scratch.id)
                    open(updated, recordHistory: false)
                    focusEditor()
                } else {
                    editor.setLanguage(language)
                }
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Rename & delete

    /// Inline rename in the toolbar title when it's visible, otherwise a small sheet.
    private func beginRename() {
        guard let current, current.isListed else { return }
        if titleField.window != nil, !titleField.isHidden, window?.toolbar?.isVisible == true {
            titleField.beginRename()
        } else {
            renameWithAlert()
        }
    }

    private func renameCurrent(to name: String) {
        guard let scratch = current else { return }
        editor.flush { [self] in
            do {
                let updated = try store.rename(scratch, to: name)
                replaceCurrent(with: updated, from: scratch)
                editor.setLanguage(updated.language)
                showMessage("Renamed to \(updated.name)")
            } catch {
                titleField.show(scratch.name)
                presentError(error)
            }
        }
    }

    /// Renames any scratch, keeping the editor's cached state and the recent list pointing at it.
    private func rename(_ scratch: Scratch, to name: String) {
        if scratch == current { return renameCurrent(to: name) }
        do {
            let updated = try store.rename(scratch, to: name)
            relocated(scratch, to: updated)
            refreshList(select: current)
            showMessage("Renamed to \(updated.name)")
        } catch {
            refreshList(select: current)
            presentError(error)
        }
    }

    private func recordVisit(_ scratch: Scratch) {
        if history.indices.contains(historyIndex), history[historyIndex] == scratch.id { return }
        history = Array(history.prefix(historyIndex + 1)) + [scratch.id]
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyIndex = history.count - 1
    }

    /// The scratch a history entry names, if it still exists.
    private func historyTarget(_ id: String) -> Scratch? { scratch(forId: id) }

    /// ⌥⌘← / ⌥⌘→: walks the visit history as far as it goes, skipping files that no longer exist. The position
    /// moves right away, so repeated presses keep going even while the previous file is still loading.
    private func navigate(back: Bool) {
        // Back from a tool page returns to the scratch underneath it.
        if back, activeTool != nil, let current {
            open(current, recordHistory: false)
            return focusEditor()
        }
        var index = historyIndex
        while true {
            index += back ? -1 : 1
            guard history.indices.contains(index) else { return NSSound.beep() }
            if history[index] != current?.id, let target = historyTarget(history[index]) {
                historyIndex = index
                editor.flush { [self] in
                    // A later press may already have moved on; only the latest target is opened.
                    guard historyIndex == index else { return }
                    sidebar.reload(store.list(), select: target.isListed ? target : nil)
                    open(target, recordHistory: false)
                    focusEditor()
                }
                return
            }
        }
    }

    private var canNavigate: (back: Bool, forward: Bool) {
        (historyIndex > 0 || (activeTool != nil && current != nil), historyIndex < history.count - 1)
    }

    private func remapHistory(_ transform: (String) -> String?) {
        history = history.map { transform($0) ?? $0 }
    }

    /// Keeps the editor cache, the open scratch and the recent list pointing at a scratch that moved on disk.
    private func relocated(_ old: Scratch, to new: Scratch) {
        guard old != new else { return }
        if richPage.scratch == old { richPage.retarget(new) }
        if old == current {
            editor.rename(from: old.id, to: new.id)
            current = new
            Settings.shared.lastScratch = new.id
            updateChrome()
        } else {
            editor.rename(from: old.id, to: new.id)
        }
        Settings.shared.recentScratches = Settings.shared.recentScratches.map { $0 == old.id ? new.id : $0 }
        remapHistory { $0 == old.id ? new.id : nil }
        tabs = tabs.map { $0 == old ? new : $0 }
        refreshTabs()
    }

    /// Same as `relocated` for everything inside a folder that was renamed or moved.
    private func relocatedFolder(from old: String, to new: String) {
        guard old != new else { return }
        func remap(_ id: String) -> String? { id.hasPrefix(old + "/") ? new + id.dropFirst(old.count) : nil }
        if let current, let id = remap(current.id) {
            relocated(current, to: Scratch(url: folderURL(forId: id).standardizedFileURL))
        }
        Settings.shared.recentScratches = Settings.shared.recentScratches.map { remap($0) ?? $0 }
        remapHistory(remap)
        tabs = tabs.map { tab in remap(tab.id).flatMap(scratch(forId:)) ?? tab }
        refreshTabs()
        if let last = Settings.shared.lastScratch.flatMap(remap) { Settings.shared.lastScratch = last }
    }

    // MARK: Folders

    /// The folders column widens the sidebar instead of squeezing the scratch list.
    private func toggleFoldersPane() {
        let on = !sidebar.isFoldersPane
        let width = sidebar.view.frame.width
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebarItem.maximumThickness = on ? 720 : 420
        sidebar.setFoldersPane(on)
        let target = on ? min(width + 180, 620) : max(width - 180, sidebarItem.minimumThickness)
        outerSplit.splitView.setPosition(target, ofDividerAt: 0)
    }

    private func createFolder(in parent: String? = nil) {
        do {
            let folder = try store.createFolder(in: parent ?? sidebar.targetFolder ?? "")
            refreshList(select: current)
            sidebar.beginRename(folder)
        } catch {
            presentError(error)
        }
    }

    private func renameFolder(_ folder: ScratchFolder, to name: String) {
        editor.flush { [self] in
            do {
                let updated = try store.renameFolder(folder, to: name)
                relocatedFolder(from: folder.id, to: updated.id)
                refreshList(select: current)
                showMessage("Renamed folder to \(updated.name)")
            } catch {
                refreshList(select: current)
                presentError(error)
            }
        }
    }

    private func move(_ scratches: [Scratch], folders: [ScratchFolder], to target: String) {
        editor.flush { [self] in
            var moved = 0
            for folder in folders {
                do {
                    let updated = try store.moveFolder(folder, to: target)
                    relocatedFolder(from: folder.id, to: updated.id)
                    moved += 1
                } catch {
                    presentError(error)
                }
            }
            for scratch in scratches {
                do {
                    let updated = try store.move(scratch, to: target)
                    relocated(scratch, to: updated)
                    moved += 1
                } catch {
                    presentError(error)
                }
            }
            refreshList(select: current)
            if moved > 0 {
                let place = target.isEmpty ? "the top level" : (target as NSString).lastPathComponent
                showMessage(moved == 1 ? "Moved to \(place)" : "Moved \(moved) items to \(place)")
            }
        }
    }

    private func deleteFolder(_ folder: ScratchFolder) {
        guard let window else { return }
        let count = store.list().filter { folder.contains($0.id) }.count
        let alert = NSAlert()
        alert.messageText = "Move folder “\(folder.name)” to the Trash?"
        alert.informativeText = count == 0 ? "The folder is empty."
            : "It contains \(count == 1 ? "1 file" : "\(count) files"). You can restore it from the Trash."
        if folder.isExternal {
            alert.informativeText += "\n\nThis is the real folder at \(ExternalFolders.displayPath(folder.id)), not a copy."
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try store.deleteFolder(folder)
            } catch {
                presentError(error)
                return
            }
            refreshList(select: current)
            dropTabs { folder.contains($0.id) }
        }
    }

    private func renameWithAlert() {
        guard let scratch = current, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Scratch"
        alert.informativeText = "The extension decides the language (.json, .md, .java, .py, …)."
        let field = NSTextField(string: scratch.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn { renameCurrent(to: field.stringValue) }
        }
        let stem = Language.stem(of: scratch.name)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    private func delete(_ scratches: [Scratch]) {
        guard !scratches.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = scratches.count == 1
            ? "Move “\(scratches[0].name)” to the Trash?"
            : "Move \(scratches.count) scratches to the Trash?"
        alert.informativeText = "You can restore them from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            for scratch in scratches {
                do {
                    try store.delete(scratch)
                    editor.forget(id: scratch.id)
                } catch {
                    presentError(error)
                }
            }
            sidebar.reload(store.list(), select: current.flatMap { scratches.contains($0) ? nil : $0 })
            dropTabs { scratches.contains($0) }
        }
    }

    private func step(_ delta: Int) {
        let list = sidebar.orderedScratches
        guard !list.isEmpty else { return }
        let index = current.flatMap { list.firstIndex(of: $0) } ?? 0
        let next = list[(index + delta + list.count) % list.count]
        sidebar.reload(store.list(), select: next)
        open(next)
    }

    private func importFiles(_ urls: [URL], into folder: String? = nil) {
        var last: Scratch?
        for url in urls {
            do {
                last = try store.importFile(url, into: folder ?? newScratchFolder)
            } catch {
                presentError(error)
            }
        }
        if let last {
            refreshList(select: last)
            open(last)
            showMessage(urls.count == 1 ? "Imported \(last.name)" : "Imported \(urls.count) files")
        }
    }

    // MARK: Clipboard

    private func copyPath(_ scratches: [Scratch]) {
        guard !scratches.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(scratches.map(\.url.path).joined(separator: "\n"), forType: .string)
        showMessage(scratches.count == 1 ? "Copied path of \(scratches[0].name)" : "Copied \(scratches.count) paths")
    }

    /// Puts the files themselves on the pasteboard, so Finder, Slack, Mail… paste them as attachments.
    private func copyFiles(_ scratches: [Scratch]) {
        guard !scratches.isEmpty else { return }
        editor.flush { [self] in
            store.flushWrites()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(scratches.map { $0.url as NSURL })
            showMessage(scratches.count == 1 ? "Copied file \(scratches[0].name)" : "Copied \(scratches.count) files")
        }
    }

    // MARK: Diff

    private func compare(_ scratches: [Scratch]) {
        guard scratches.count == 2 else {
            showMessage("Select two scratches in the list (⌘-click) to compare them", isError: true)
            return
        }
        editor.flush { [self] in
            store.flushWrites()
            let (a, b) = (scratches[0], scratches[1])
            editor.showDiff(left: (a.name, store.read(a)), right: (b.name, store.read(b)), language: a.language)
            isDiffing = true
            showMessage("Comparing \(a.name) ↔ \(b.name) — Esc to close")
        }
    }

    private func compareWithClipboard() {
        guard let scratch = current else { return }
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        editor.text { [self] text in
            guard let text else { return }
            editor.showDiff(left: (scratch.name, text), right: ("Clipboard", clip), language: scratch.language)
            isDiffing = true
            showMessage("Comparing \(scratch.name) ↔ Clipboard — Esc to close")
        }
    }

    // MARK: New scratch picker

    /// Type-to-filter file type chooser; Return on the first row keeps the auto-detect behaviour.
    private func showNewScratchMenu(in target: String? = nil) {
        let folder = target ?? newScratchFolder
        newScratchPicker.placeholder = folder.isEmpty ? "File type — type to filter" : "File type — new scratch in \(folder)/"
        var items = [PaletteItem(id: "new.text", title: "Auto-detect on Paste", category: "plain text until you paste",
                                 keywords: "text txt plain auto detect") { [weak self] in
            self?.createScratch(.text, in: folder)
        }]
        items.append(PaletteItem(id: "new.plaintext", title: "Plain Text", category: ".txt  — stays plain text",
                                 keywords: "text txt plain log", icon: (Language.text.symbolName, Language.text.tint)) { [weak self] in
            guard let self, let scratch = self.createScratch(.text, in: folder) else { return }
            self.explicitPlainText.insert(scratch.id)
        })
        for lang in Language.allCases where lang != .text {
            let extensions = lang.fileExtensions.map { ".\($0)" }.joined(separator: "  ")
            items.append(PaletteItem(id: "new.\(lang.rawValue)", title: lang.displayName, category: extensions,
                                     keywords: lang.fileExtensions.joined(separator: " ")) { [weak self] in
                self?.createScratch(lang, in: folder)
            })
        }
        items.append(PaletteItem(id: "new.folder", title: "Folder", category: folder.isEmpty ? "new folder" : "new folder in \(folder)/",
                                 keywords: "folder directory dir group") { [weak self] in
            self?.createFolder(in: folder)
        })
        newScratchPicker.show(over: window, items: items)
    }

    // MARK: Breadcrumbs

    private func showPathMenu(_ index: Int, from view: NSView) {
        if activeTool != nil {
            toolsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            return
        }
        guard let current else { return }
        let menu: NSMenu
        if current.isSharedManifest {
            menu = index == 0 ? sharedPackagesMenu() : fileMenu(for: current)
        } else if !current.isListed {
            if index == 0 {
                menu = NSMenu()
                menu.addItem(finderItem(current.url.deletingLastPathComponent()))
            } else {
                menu = fileMenu(for: current)
            }
        } else {
            let crumbs = breadcrumb(for: current)
            menu = index >= crumbs.count ? fileMenu(for: current) : folderMenu(crumbs[index].id)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// Subfolders and scratches of a folder ("" for the top level), plus actions for it.
    private func folderMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        let showItem = ClosureMenuItem(title: "Show in Sidebar") { [weak self] in
            guard let self else { return }
            if self.sidebarItem.isCollapsed { self.sidebarItem.animator().isCollapsed = false }
            self.sidebar.showFolder(id)
        }
        showItem.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        menu.addItem(showItem)
        let newItem = ClosureMenuItem(title: "New Scratch Here…") { [weak self] in self?.showNewScratchMenu(in: id) }
        newItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(newItem)
        menu.addItem(finderItem(folderURL(forId: id)))
        let findItem = ClosureMenuItem(title: "Find in This Folder…") { [weak self] in self?.findInFolder(id) }
        findItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(findItem)

        let subfolders = ScratchStore.folders().filter { $0.parent == id && (id.isEmpty ? !$0.isExternal : true) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let scratches = sidebar.scratches.filter { $0.isListed && $0.folder == id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !subfolders.isEmpty || !scratches.isEmpty { menu.addItem(.separator()) }
        for folder in subfolders {
            let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))
            item.submenu = folderMenu(folder.id)
            menu.addItem(item)
        }
        for scratch in scratches {
            let item = ClosureMenuItem(title: scratch.name) { [weak self] in self?.open(scratch) }
            item.image = NSImage(systemSymbolName: scratch.language.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [scratch.language.tint]))
            item.state = scratch == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func fileMenu(for scratch: Scratch) -> NSMenu {
        let menu = NSMenu()
        var ids = ["revealInSidebar", "revealScratch", "copyPath", "copyFile"]
        if scratch.isListed { ids.insert("renameScratch", at: 0) }
        for id in ids where isEnabled(id) {
            guard let title = Actions.byId[id]?.title else { continue }
            let item = ClosureMenuItem(title: title) { [weak self] in self?.perform(id) }
            if let key = KeymapStore.shared.key(for: id) { item.toolTip = key.display }
            menu.addItem(item)
        }
        if !scratch.isInScratchFolder, !scratch.isSharedManifest {
            menu.addItem(ClosureMenuItem(title: "Copy into Scratches") { [weak self] in self?.importFiles([scratch.url]) })
        }
        menu.addItem(.separator())
        let language = ClosureMenuItem(title: "Change File Type…") { [weak self] in
            guard let self else { return }
            self.showLanguageMenu(from: self.languageButton)
        }
        menu.addItem(language)
        return menu
    }

    private func sharedPackagesMenu() -> NSMenu {
        let menu = NSMenu()
        for id in ["installSharedPackages"] where isEnabled(id) {
            menu.addItem(ClosureMenuItem(title: Actions.byId[id]?.title ?? id) { [weak self] in self?.perform(id) })
        }
        menu.addItem(finderItem(AppPaths.packages))
        return menu
    }

    private func finderItem(_ url: URL) -> NSMenuItem {
        let item = ClosureMenuItem(title: "Open in Finder") { NSWorkspace.shared.open(url) }
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        return item
    }

    // MARK: Code actions

    private func format(compact: Bool) {
        guard let scratch = current else { return }
        guard compact ? scratch.language.canCompact : scratch.language.canFormat else {
            showMessage("No \(compact ? "compactor" : "formatter") for \(scratch.language.displayName)", isError: true)
            return
        }
        editor.format(compact: compact) { [weak self] error in
            if let error {
                self?.showMessage(error, isError: true)
                NSSound.beep()
            } else {
                self?.showMessage(compact ? "Compacted" : "Formatted")
            }
        }
    }

    private func run() {
        if current?.language == .http { return runHTTP(at: nil, all: false) }
        if current?.isSharedManifest == true { return installSharedPackages() }
        guard let scratch = current, scratch.language.canRun else {
            showMessage("\(current?.language.displayName ?? "This") scratch can't be run", isError: true)
            return
        }
        editor.text { [self] text in
            guard let text else { return }
            store.save(scratch, text: text)
            showConsole(true)
            console.clear()
            console.setTitle(scratch.name)
            console.setRunning()
            runner.run(language: scratch.language, source: text)
            updateToolbarState()
        }
    }

    // MARK: Shared packages & JDK

    private func openSharedPackages() {
        do {
            let url = try SharedPackages.ensureManifest()
            editor.flush { [self] in
                sidebar.reload(store.list(), select: nil)
                open(Scratch(url: url))
                focusEditor()
                showMessage("Shared packages for every JS/TS scratch. Add dependencies, then Run to npm install.")
            }
        } catch {
            presentError(error)
        }
    }

    private func installSharedPackages() {
        let start = { [self] in
            showConsole(true)
            console.clear()
            console.setTitle("npm install")
            console.setRunning()
            runner.installSharedPackages()
            updateToolbarState()
        }
        guard let current, current.isSharedManifest else { return start() }
        editor.text { [self] text in
            if let text { store.save(current, text: text); store.flushWrites() }
            start()
        }
    }

    private func updateJDKButton() {
        DispatchQueue.global().async {
            let jdk = Toolchains.resolveJDK()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let title = jdk.map { $0.majorVersion > 0 ? "Java \($0.majorVersion)" : $0.version } ?? "No JDK"
                self.jdkButton.show(symbol: "cup.and.saucer.fill", tint: Language.java.tint, title: title,
                                    accessibility: "JDK: \(title)")
                self.jdkButton.toolTip = jdk.map { "\($0.name) (\($0.version))\n\($0.home)" } ?? "No JDK found"
            }
        }
    }

    private func showJDKMenu(from button: NSView?) {
        let jdks = Toolchains.installedJDKs()
        let active = Toolchains.resolveJDK()
        let menu = NSMenu()
        if jdks.isEmpty {
            let none = NSMenuItem(title: "No JDKs found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for jdk in jdks {
            let item = NSMenuItem(title: "\(jdk.name) — \(jdk.version)", action: #selector(jdkChosen(_:)), keyEquivalent: "")
            item.representedObject = jdk.home
            item.toolTip = jdk.home
            item.target = self
            item.state = jdk == active ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "JDK Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ""))
        if let button, button.window != nil {
            menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        } else {
            let view = editorPane.view
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX - 120, y: view.bounds.maxY - 40), in: view)
        }
    }

    @objc private func jdkChosen(_ sender: NSMenuItem) {
        guard let home = sender.representedObject as? String,
              let jdk = Toolchains.installedJDKs().first(where: { $0.home == home }) else { return }
        Settings.shared.javaHome = jdk.home
        Settings.shared.javaVersion = jdk.majorVersion
        showMessage("Java scratches now run with \(jdk.name)")
    }

    // MARK: HTTP

    /// Runs the request at `offset` (the caret when nil), or every request in the file.
    private func runHTTP(at offset: Int?, all: Bool) {
        guard let scratch = current, scratch.language == .http else {
            showMessage("Requests can only be run from an HTTP scratch", isError: true)
            return
        }
        editor.textAndCursor { [self] text, cursor in
            guard let text, current == scratch else { return }
            store.save(scratch, text: text)
            let file = HTTPFile.parse(text)
            let requests: [HTTPRequest]
            if all {
                requests = file.requests
            } else if let request = file.request(at: offset ?? cursor) {
                requests = [request]
            } else {
                requests = []
            }
            guard !requests.isEmpty else {
                showMessage(file.requests.isEmpty ? "No requests in this file" : "Place the caret inside a request to run it",
                            isError: true)
                return
            }
            do {
                let resolved = try requests.map { try file.resolve($0) }
                http.stop()
                httpRun = (scratch.id, resolved)
                editor.httpStarted(scratchId: scratch.id, requests: resolved.map {
                    ["title": $0.title, "name": $0.name ?? "", "method": $0.method, "url": $0.url, "line": $0.lineOffset]
                })
                http.send(resolved, baseDirectory: scratch.url.deletingLastPathComponent())
                updateToolbarState()
            } catch {
                showMessage(error.localizedDescription, isError: true)
                NSSound.beep()
            }
        }
    }

    private func reportHTTPResult(_ index: Int, _ result: Result<HTTPResponse, Error>) {
        guard let run = httpRun, run.requests.indices.contains(index) else { return }
        let request = run.requests[index]
        var payload: [String: Any] = ["curl": Curl.export(request)]
        switch result {
        case .failure(let error):
            payload["error"] = error.localizedDescription
        case .success(let response):
            payload["status"] = response.status
            payload["reason"] = HTTPClient.reason(response.status)
            payload["elapsedMs"] = Int((response.elapsed * 1000).rounded())
            payload["size"] = HTTPClient.size(response.body.count)
            payload["headers"] = response.headers.map { [$0.name, $0.value] }
            payload["contentType"] = response.contentType ?? ""
            if let finalURL = response.finalURL { payload["redirectedTo"] = finalURL.absoluteString }
            if let text = response.displayBody(indent: Settings.shared.tabSize) {
                let limit = 2_000_000
                payload["body"] = text.utf16.count > limit ? String(text.prefix(limit)) : text
                payload["truncated"] = text.utf16.count > limit
                payload["language"] = response.language.rawValue
            } else if response.isImage, response.body.count < 5_000_000 {
                payload["image"] = "data:\(response.contentType ?? "image/png");base64,\(response.body.base64EncodedString())"
            }
        }
        editor.httpResult(scratchId: run.scratchId, index: index, result: payload)
    }

    private func copyRequestAsCurl() {
        guard current?.language == .http else { return }
        editor.textAndCursor { [self] text, cursor in
            guard let text else { return }
            let file = HTTPFile.parse(text)
            guard let request = file.request(at: cursor) else {
                showMessage("Place the caret inside a request to copy it", isError: true)
                return
            }
            do {
                let command = Curl.export(try file.resolve(request))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                showMessage("Copied \(request.method) request as cURL")
            } catch {
                showMessage(error.localizedDescription, isError: true)
                NSSound.beep()
            }
        }
    }

    /// Converts the clipboard's curl command into the current HTTP scratch, or a new one.
    private func importCurlFromClipboard() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        guard Curl.looksLikeCurl(clip) else {
            showMessage("The clipboard doesn't contain a curl command", isError: true)
            NSSound.beep()
            return
        }
        if current?.language == .http {
            editor.textAndCursor { [self] text, cursor in
                let ns = (text ?? "") as NSString
                let before = ns.substring(to: min(cursor, ns.length)).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = ns.substring(from: min(cursor, ns.length)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lastLine = before.components(separatedBy: "\n").last ?? ""
                insertCurl(clip, separatorBefore: !before.isEmpty && !lastLine.hasPrefix("###"),
                           separatorAfter: !after.isEmpty && !after.hasPrefix("###"))
            }
        } else {
            do {
                createScratch(.http, content: try Curl.toHTTP(clip, indent: Settings.shared.tabSize) + "\n")
                showMessage("Converted cURL to an HTTP request")
            } catch {
                showMessage("cURL: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func insertCurl(_ command: String, separatorBefore: Bool, separatorAfter: Bool) {
        do {
            var converted = try Curl.toHTTP(command, indent: Settings.shared.tabSize)
            if separatorBefore { converted = "\n\n###\n" + converted }
            if separatorAfter { converted += "\n\n###\n" } else { converted += "\n" }
            editor.insertAtCursors(converted)
            showMessage("Converted cURL to an HTTP request")
        } catch {
            editor.insertAtCursors(command)
            showMessage("Pasted as text: \(error.localizedDescription)", isError: true)
        }
    }

    private func openLastResponse() {
        guard let response = http.lastResponse else {
            showMessage("Run a request first", isError: true)
            return
        }
        guard let text = response.displayBody(indent: Settings.shared.tabSize), !text.isEmpty else {
            showMessage("The last response has no text body", isError: true)
            return
        }
        createScratch(response.language, content: text)
    }

    private func showFindInScratches() {
        editor.selectionText { [self] selection in
            editor.flush { [self] in
                findInScratches.show(over: window, query: selection)
            }
        }
    }

    private func setPreview(_ mode: PreviewMode) {
        Settings.shared.previewMode = mode
        editor.setPreview(mode)
        updatePreviewControl()
    }

    private func togglePreview(_ mode: PreviewMode) {
        guard current != nil, editor.previewAvailable else {
            showMessage("Preview is available for Markdown, HTML, CSV, TSV and OpenAPI (Swagger) specs", isError: true)
            return
        }
        let currentMode = Settings.shared.previewMode
        if currentMode == mode {
            // Leaving full preview returns to the editor layout used before it.
            setPreview(mode == .full ? previewBeforeFull : .off)
        } else {
            if mode == .full { previewBeforeFull = currentMode }
            setPreview(mode)
        }
    }

    private static let previewModes: [PreviewMode] = [.off, .split, .full]

    /// The preview switcher only appears for file types that have a preview.
    private func updatePreviewControl() {
        let visible = current != nil && editor.previewAvailable
        previewGroup.isHidden = !visible
        let kind = activeTool == nil ? exportKind : nil
        exportButton.isHidden = kind == nil
        exportButton.toolTip = kind == "openapi" ? "Export API reference (HTML, MHTML)…" : "Export preview (PDF, HTML, MHTML)…"
        viewerButton.isHidden = kind != "openapi"
        let viewer = Settings.shared.specViewer
        viewerButton.show(symbol: viewer.symbol, tint: .secondaryLabelColor, title: viewer.title,
                          accessibility: "OpenAPI viewer: \(viewer.title)")
        viewerButton.toolTip = "Show the spec in Swagger UI, Scalar or Kong"
        for (button, mode) in zip(previewButtons, Self.previewModes) {
            button.state = visible && Settings.shared.previewMode == mode ? .on : .off
        }
    }

    @objc private func previewButtonClicked(_ sender: HoverButton) {
        setPreview(Self.previewModes[sender.tag])
    }

    private func updateToolbarState() {
        for (id, button) in toolbarButtons { button.isEnabled = isEnabled(id) }
        toolbarButtons["toggleConsole"]?.state = consoleItem.isCollapsed ? .off : .on
        languageButton.isEnabled = current != nil
        window?.toolbar?.validateVisibleItems()
    }

    private func showConsole(_ show: Bool) {
        if consoleItem.isCollapsed == show {
            consoleItem.animator().isCollapsed = !show
        }
        toolbarButtons["toggleConsole"]?.state = show ? .on : .off
        if show, innerSplit.splitView.subviews.count == 2 {
            let isRight = Settings.shared.consolePosition == .right
            let currentSize = isRight ? console.view.frame.width : console.view.frame.height
            let minComfortable: CGFloat = isRight ? 240 : 180
            if currentSize < minComfortable {
                let total = isRight ? innerSplit.splitView.bounds.width : innerSplit.splitView.bounds.height
                let desired: CGFloat = isRight ? 320 : 220
                innerSplit.splitView.setPosition(max(200, total - desired), ofDividerAt: 0)
            }
        }
    }

    private func toggleConsolePosition() {
        let newPos: ConsolePosition = Settings.shared.consolePosition == .bottom ? .right : .bottom
        Settings.shared.consolePosition = newPos
        applyConsolePosition()
    }

    private func applyConsolePosition() {
        let isRight = Settings.shared.consolePosition == .right
        innerSplit.splitView.isVertical = isRight
        consoleItem.minimumThickness = isRight ? 180 : 120
        console.setPosition(Settings.shared.consolePosition)
        if !consoleItem.isCollapsed {
            let total = isRight ? innerSplit.splitView.bounds.width : innerSplit.splitView.bounds.height
            let size: CGFloat = isRight ? 320 : 220
            innerSplit.splitView.setPosition(max(200, total - size), ofDividerAt: 0)
        }
    }

    private var sidebarHasFocus: Bool {
        guard !sidebarItem.isCollapsed, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: sidebar.view)
    }

    /// Hides the scratch list and console; pressing again brings back what was showing.
    private func toggleEditorOnly() {
        if !sidebarItem.isCollapsed || !consoleItem.isCollapsed {
            layoutBeforeEditorOnly = (!sidebarItem.isCollapsed, !consoleItem.isCollapsed)
            sidebarItem.animator().isCollapsed = true
            showConsole(false)
        } else {
            let (sidebarShown, consoleShown) = layoutBeforeEditorOnly ?? (true, false)
            layoutBeforeEditorOnly = nil
            if sidebarShown { sidebarItem.animator().isCollapsed = false }
            if consoleShown { showConsole(true) }
        }
        focusEditor()
    }

    /// Shows the scratch list if hidden and selects, scrolls to and briefly highlights the open scratch.
    private func revealInSidebar() {
        if let tool = activeTool {
            if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
            return sidebar.setActiveTool(tool.id)
        }
        guard let current else { return }
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebar.reveal(current)
    }

    // MARK: Export & OpenAPI viewers

    /// "markdown" or "openapi" when the open file's preview can be exported.
    private var exportKind: String? {
        guard current != nil, activeTool == nil, !isDiffing, let kind = editor.previewKind,
              ["markdown", "openapi"].contains(kind) else { return nil }
        return kind
    }

    private var exportPopover: NSPopover?

    private func setSpecViewer(_ viewer: SpecViewer) {
        Settings.shared.specViewer = viewer
        editor.setSpecViewer(viewer)
        updatePreviewControl()
    }

    private func showViewerMenu(from button: NSView) {
        let menu = NSMenu()
        for viewer in SpecViewer.allCases {
            let item = ClosureMenuItem(title: viewer.title) { [weak self] in self?.setSpecViewer(viewer) }
            item.image = NSImage(systemSymbolName: viewer.symbol, accessibilityDescription: nil)
            item.state = viewer == Settings.shared.specViewer ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func exportButtonClicked(_ sender: NSView) {
        showExportPopover()
    }

    private func showExportPopover() {
        guard let kind = exportKind else { return }
        let controller: ExportPopoverController
        let run: (ExportFormat, SpecViewer?) -> Void = { [weak self] format, viewer in
            self?.exportPopover?.performClose(nil)
            self?.exportPopover = nil
            // After the popover has gone: the save sheet can't start while it is closing.
            DispatchQueue.main.async { self?.exportPreview(format, viewer: viewer) }
        }
        if kind == "openapi" {
            controller = ExportPopoverController(heading: "Export API Reference", options: [
                .init(format: .html, title: "HTML", detail: "Interactive page with the viewer and the spec built in. Works offline.",
                      symbol: "safari"),
                .init(format: .mhtml, title: "MHTML", detail: "Static snapshot with everything expanded, in one file (Chrome, Edge).",
                      symbol: "doc.richtext"),
            ], viewers: SpecViewer.allCases, viewer: Settings.shared.specViewer, onExport: run)
        } else {
            controller = ExportPopoverController(heading: "Export Preview", options: [
                .init(format: .pdf, title: "PDF", detail: "Paginated document for printing and sharing.", symbol: "doc.text"),
                .init(format: .html, title: "HTML", detail: "Standalone web page, styles and diagrams built in.", symbol: "safari"),
                .init(format: .mhtml, title: "MHTML", detail: "Web archive in one file, images included (Chrome, Edge, Word).",
                      symbol: "doc.richtext"),
            ], viewers: [], viewer: Settings.shared.specViewer, onExport: run)
        }
        exportPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        exportPopover = popover
        if !exportButton.isHidden, exportButton.window != nil {
            popover.show(relativeTo: exportButton.bounds, of: exportButton, preferredEdge: .maxY)
        } else if let content = window?.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 90, width: 1, height: 1),
                         of: content, preferredEdge: .minY)
        }
    }

    /// Saves the preview (Markdown) or an API reference page (OpenAPI) in Downloads unless another place is chosen.
    private func exportPreview(_ format: ExportFormat, viewer chosen: SpecViewer? = nil) {
        guard let scratch = current, let kind = exportKind, let window else { return }
        if format == .pdf && kind != "markdown" { return }
        let viewer = chosen ?? Settings.shared.specViewer
        let title = Language.stem(of: scratch.name)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = title + (kind == "openapi" ? " (\(viewer.title))" : "") + "." + format.fileExtension
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if format == .mhtml { Toast.show("Exporting \(url.lastPathComponent)…", symbol: "hourglass", tint: .secondaryLabelColor, in: self.window) }
            if kind == "markdown" {
                self.exportMarkdown(format, title: title, to: url)
            } else {
                self.exportSpec(format, viewer: viewer, title: title, to: url)
            }
        }
    }

    private func exportMarkdown(_ format: ExportFormat, title: String, to url: URL) {
        editor.previewDocument(title: title, forPrint: format == .pdf) { [weak self] html in
            guard let self else { return }
            guard let html else { return self.exportFinished(url, ok: false) }
            switch format {
            case .pdf:
                PDFExport.write(html: html, to: url, window: self.window) { [weak self] ok in self?.exportFinished(url, ok: ok) }
            case .html:
                self.write(Data(html.utf8), to: url)
            case .mhtml:
                MHTML.make(html: html, title: title) { [weak self] data in self?.write(data, to: url) }
            }
        }
    }

    private func exportSpec(_ format: ExportFormat, viewer: SpecViewer, title: String, to url: URL) {
        editor.text { [weak self] spec in
            guard let self else { return }
            guard let spec, let page = SpecPage.html(viewer: viewer, spec: spec, title: title, snapshot: format == .mhtml) else {
                return self.exportFinished(url, ok: false)
            }
            guard format == .mhtml else { return self.write(Data(page.utf8), to: url) }
            PageSnapshot.capture(html: page) { [weak self] snapshot in
                guard let self else { return }
                guard let snapshot else { return self.exportFinished(url, ok: false) }
                MHTML.make(html: snapshot, title: title) { [weak self] data in self?.write(data, to: url) }
            }
        }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            exportFinished(url, ok: true)
        } catch {
            NSLog("ScratchPad: export failed: \(error)")
            exportFinished(url, ok: false)
        }
    }

    private func exportFinished(_ url: URL, ok: Bool) {
        if ok {
            Toast.show("Saved \(url.lastPathComponent)", in: window, actions: [
                .init(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                .init(title: "Open") { NSWorkspace.shared.open(url) },
            ])
        } else {
            showMessage("Couldn't export \(url.lastPathComponent)", isError: true)
        }
    }

    private func showLanguageMenu(from button: NSView) {
        let menu = NSMenu()
        for (index, lang) in Language.allCases.enumerated() {
            let item = NSMenuItem(title: lang.displayName, action: #selector(changeLanguageFromMenu(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = lang == current?.language ? .on : .off
            item.image = NSImage(systemSymbolName: lang.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [lang.tint]))
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func showMessage(_ text: String, isError: Bool = false) {
        if showsRichText || activeTool != nil {
            // Pages have no status bar.
            Toast.show(text, symbol: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                       tint: isError ? .systemOrange : .systemGreen, in: window)
            return
        }
        editorPane.setMessage(text, isError: isError)
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: isError ? 8 : 3, repeats: false) { [weak self] _ in
            self?.editorPane.setMessage("", isError: false)
        }
    }

    // MARK: Palette & transforms

    private func showPalette() {
        let store = KeymapStore.shared
        var items: [PaletteItem] = Transforms.all.map { t in
            PaletteItem(id: "transform.\(t.id)", title: t.title, category: t.category, keywords: t.keywords) { [weak self] in
                self?.apply(t)
            }
        }
        for tool in DevTools.all {
            items.append(PaletteItem(id: "tool.\(tool.id)", title: "\(tool.title) Tool", category: "Dev Tools",
                                     keywords: "\(tool.summary) \(tool.keywords)",
                                     icon: (tool.symbol, tool.tint)) { [weak self] in
                self?.editor.flush { self?.openTool(tool.id) }
            })
        }
        for action in Actions.all where action.scope != .sidebar && action.id != "commandPalette" {
            items.append(PaletteItem(id: "action.\(action.id)", title: action.title.replacingOccurrences(of: "…", with: ""),
                                     category: action.category, shortcut: store.key(for: action.id)?.display) { [weak self] in
                self?.perform(action.id)
            })
        }
        items.append(PaletteItem(id: "action.sidebarCompare", title: "Compare Selected Scratches", category: "Scratch",
                                 shortcut: store.key(for: "sidebarCompare").map { "\($0.display) in list" }) { [weak self] in
            guard let self else { return }
            self.compare(self.sidebar.selectedScratches)
        })
        for lang in Language.allCases {
            items.append(PaletteItem(id: "language.\(lang.rawValue)", title: "Change Language to \(lang.displayName)",
                                     category: "Language", keywords: lang.fileExtensions.joined(separator: " ")) { [weak self] in
                self?.changeLanguage(to: lang)
            })
            items.append(PaletteItem(id: "new.\(lang.rawValue)", title: "New \(lang.displayName) Scratch", category: "New",
                                     keywords: lang.fileExtensions.joined(separator: " ")) { [weak self] in
                self?.createScratch(lang)
            })
        }
        palette.show(over: window, items: items)
    }

    /// ⌘E: recently opened scratches (most recent first, then the rest by edit time), with the
    /// previously opened one highlighted so Return switches back to it.
    private func showRecentScratches() {
        let all = store.list()
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = Settings.shared.recentScratches.compactMap { byId[$0] }
        if let current, !ordered.contains(current) { ordered.insert(current, at: 0) }
        ordered += all.filter { !ordered.contains($0) }.sorted { $0.modified > $1.modified }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        let scratchItems = ordered.map { scratch in
            let age = Date().timeIntervalSince(scratch.modified)
            let edited = age < 60 ? "just now" : relative.localizedString(for: scratch.modified, relativeTo: Date())
            let detail = scratch == current ? "current" : "edited \(edited)"
            return PaletteItem(id: "scratch.\(scratch.id)", title: scratch.name, category: detail,
                               keywords: scratch.language.displayName,
                               icon: (scratch.language.symbolName, scratch.language.tint)) { [weak self] in
                guard let self else { return }
                self.window?.makeKeyAndOrderFront(nil)
                if scratch != self.current || self.isDiffing || self.activeTool != nil {
                    self.sidebar.reload(self.store.list(), select: scratch)
                    self.open(scratch)
                }
                self.focusEditor()
            }
        }
        let files = openedFiles.filter { $0 != current }.map { file in
            PaletteItem(id: "file.\(file.id)", title: file.name, category: "Opened file · \(Self.folderDisplay(file))",
                        keywords: file.url.path, icon: (file.language.symbolName, file.language.tint)) { [weak self] in
                self?.show(file)
            }
        }
        let tools = DevTools.all.map { tool in
            PaletteItem(id: "tool.\(tool.id)", title: tool.title, category: "Dev Tools · \(tool.summary)",
                        keywords: tool.keywords, icon: (tool.symbol, tool.tint)) { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
                self?.editor.flush { self?.openTool(tool.id) }
            }
        }
        let items = scratchItems + files + tools
        let initial = ordered.first == current && ordered.count > 1 ? 1 : 0
        editor.flush { [self] in
            recentPicker.show(over: window, items: items, initialRow: initial,
                              cycleKey: KeymapStore.shared.key(for: "recentScratches"))
        }
    }

    private func apply(_ transform: TextTransform) {
        window?.makeKeyAndOrderFront(nil)
        if showsRichText {
            showMessage("Text transforms work in code and plain text scratches", isError: true)
            return
        }
        focusEditor()
        switch transform.kind {
        case .insert(let generate):
            editor.insertAtCursors(generate())
            showMessage(transform.title)
        case .info(let describe):
            editor.selections { [self] ranges, whole in
                let text = ranges.map(\.text).joined(separator: "\n")
                showMessage("\(whole ? "Document" : "Selection"): \(describe(text))")
            }
        case .map(let map):
            editor.selections { [self] ranges, whole in
                do {
                    let results = try ranges.map { TextSelection(from: $0.from, to: $0.to, text: try map($0.text)) }
                    editor.replace(results)
                    let scope = whole ? "document" : ranges.count == 1 ? "selection" : "\(ranges.count) selections"
                    showMessage("\(transform.title) applied to \(scope)")
                } catch {
                    showMessage("\(transform.title): \(error.localizedDescription)", isError: true)
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: Opening files

    /// Files opened from outside the scratch folder, most recent first. They aren't touched on disk here (that would
    /// prompt for Downloads/Desktop access); ones that have gone are dropped when opening them fails.
    private var openedFiles: [Scratch] {
        Settings.shared.openedFiles.map { Scratch(url: URL(fileURLWithPath: $0), readAttributes: false) }
    }

    private static func folderDisplay(_ scratch: Scratch) -> String {
        (scratch.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// Why a file can't be edited here, or nil when it can.
    private static func unopenableReason(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "not found" }
        if Language(fileExtension: url.pathExtension).isRichText { return nil }
        if isDirectory.boolValue { return "folders can't be opened" }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 50_000_000 { return "larger than 50 MB" }
        guard let data = try? Data(contentsOf: url) else { return "can't be read" }
        if data.prefix(8192).contains(0) { return "not a text file" }
        if String(data: data, encoding: .utf8) == nil { return "not UTF-8 text" }
        return nil
    }

    /// Opens files dropped on the Dock icon, opened from Finder, or chosen with ⌘O. Files inside the
    /// scratch folder open as scratches; others are edited in place and remembered under Recent Scratches.
    func openFiles(_ urls: [URL]) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for url in urls where url.scheme == "scratchpad" { handleCommandURL(url) }
        let fileURLs = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        let folders = fileURLs.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !RichTextIO.isPackage(url)
        }
        // Folders inside the scratches folder are already in the sidebar; just show them.
        let scratchFolders = folders.filter { relativePath($0) != nil }
        let externalFolders = folders.filter { relativePath($0) == nil }
        if !externalFolders.isEmpty { addExternalFolders(externalFolders, quiet: fileURLs.count > folders.count) }
        if let id = scratchFolders.last.flatMap(relativePath) { revealFolder(id) }
        var opened: [Scratch] = []
        var problems: [String] = []
        for url in fileURLs where !folders.contains(url) {
            if let reason = Self.unopenableReason(url) {
                problems.append("\(url.lastPathComponent) (\(reason))")
            } else {
                opened.append(Scratch(url: url))
            }
        }
        let external = opened.filter { !$0.isListed }.map(\.url.path)
        Settings.shared.openedFiles = external.reversed() + Settings.shared.openedFiles.filter { !external.contains($0) }
        guard let first = opened.first else {
            if !problems.isEmpty, folders.isEmpty {
                Toast.show("Couldn't open \(problems.joined(separator: ", "))", symbol: "exclamationmark.triangle.fill",
                           tint: .systemOrange, in: window)
            }
            return
        }
        editor.flush { [self] in
            show(first)
            var text = first.isInScratchFolder ? "Opened \(first.name)"
                : "Opened \(first.name) from \(Self.folderDisplay(first)) — changes save to the original file"
            if !folders.isEmpty { text += ". Added \(folders.count == 1 ? "1 folder" : "\(folders.count) folders") to the sidebar" }
            if opened.count > 1 { text += ". \(opened.count - 1) more in Recent Scratches" }
            if !problems.isEmpty { text += ". Couldn't open \(problems.joined(separator: ", "))" }
            Toast.show(text, symbol: problems.isEmpty ? "doc.fill" : "exclamationmark.triangle.fill",
                       tint: problems.isEmpty ? .systemBlue : .systemOrange, in: window)
        }
    }

    // MARK: External folders & command line

    private func revealFolder(_ id: String) {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebar.showFolder(id)
    }

    /// Lists folders from elsewhere on disk in the sidebar (and Find in Files) without copying them.
    func addExternalFolders(_ urls: [URL], quiet: Bool = false) {
        var added: [String] = []
        var problems: [String] = []
        for url in urls {
            do { added.append(try ExternalFolders.add(url)) } catch { problems.append(error.localizedDescription) }
        }
        if !added.isEmpty {
            store.rewatch()
            sidebar.reload(store.list(), select: current?.isListed == true ? current : nil)
            if let last = added.last { revealFolder(last) }
        }
        guard !quiet else { return }
        if !problems.isEmpty {
            Toast.show(problems.joined(separator: " "), symbol: "exclamationmark.triangle.fill", tint: .systemOrange, in: window)
        } else if let last = added.last {
            let truncated = ScratchStore.truncatedExternalRoots.contains(last)
            let text = added.count == 1
                ? "Added \(ExternalFolders.displayPath(last)) as an external folder"
                    + (truncated ? " (first \(ScratchStore.maxExternalFiles) files)" : "")
                : "Added \(added.count) external folders"
            Toast.show(text, symbol: "externaldrive.fill", tint: .systemOrange, in: window)
        }
    }

    private func removeExternalFolder(_ root: String) {
        editor.flush { [self] in
            store.flushWrites()
            ExternalFolders.remove(root)
            store.rewatch()
            sidebar.reload(store.list(), select: current?.isListed == true ? current : nil)
            updateChrome()
            Toast.show("Removed \((root as NSString).lastPathComponent) from the sidebar. The folder itself wasn't changed.",
                       symbol: "externaldrive", tint: .systemGray, in: window)
        }
    }

    private func showAddFolderPanel() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Sidebar"
        panel.message = "The folder stays where it is: its files are listed and searched, and edits save to them."
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.addExternalFolders(panel.urls) }
        }
    }

    /// `scratchpad://import?path=…` from `command | scratchpad -`: turns the piped text into a new scratch.
    private func handleCommandURL(_ url: URL) {
        guard url.host == "import",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value
        else { return }
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        // Only the CLI's own temp files: the URL can come from anywhere, and the file is deleted afterwards.
        guard file.path.hasPrefix(temp + "/") || file.path.hasPrefix("/private/tmp/") || file.path.hasPrefix("/tmp/"),
              file.lastPathComponent.hasPrefix("scratchpad-stdin.") else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            Toast.show("Nothing was piped to scratchpad", symbol: "exclamationmark.triangle.fill", tint: .systemOrange, in: window)
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        editor.flush { [self] in
            if let scratch = createScratch(Language.detect(text), content: text, in: "") {
                if scratch.language.isTable, Settings.shared.previewMode == .off { setPreview(.split) }
                Toast.show("Created \(scratch.name) from piped text", symbol: "terminal.fill", tint: .systemGreen, in: window)
            }
        }
    }

    /// Links /usr/local/bin/scratchpad to the script inside the app (asking for an admin password if needed).
    private func installCommandLineTool() {
        guard let window else { return }
        guard let script = Bundle.main.url(forResource: "scratchpad", withExtension: nil, subdirectory: "bin") else {
            presentError(ScratchStore.error("The command line tool is missing from the app bundle. Rebuild the app."))
            return
        }
        let target = "/usr/local/bin/scratchpad"
        let alert = NSAlert()
        alert.messageText = "Install the “scratchpad” command?"
        alert.informativeText = """
            Creates \(target), linked to this app. Then, in Terminal:

              scratchpad notes.md         open a file
              scratchpad ~/work/project   add a folder to the sidebar
              pbpaste | scratchpad -      open piped text as a new scratch
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let fm = FileManager.default
            do {
                try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
                if (try? fm.destinationOfSymbolicLink(atPath: target)) != nil || fm.fileExists(atPath: target) {
                    try fm.removeItem(atPath: target)
                }
                try fm.createSymbolicLink(atPath: target, withDestinationPath: script.path)
            } catch {
                let quoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let command = "mkdir -p /usr/local/bin && ln -sf \(quoted(script.path)) \(quoted(target))"
                let source = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
                var scriptError: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&scriptError)
                if let scriptError {
                    if (scriptError[NSAppleScript.errorNumber] as? Int) == -128 { return }
                    presentError(ScratchStore.error("Couldn't install \(target): \(scriptError[NSAppleScript.errorMessage] ?? "unknown error")"))
                    return
                }
            }
            Toast.show("Installed. Run “scratchpad <file or folder>” in Terminal", symbol: "terminal.fill", tint: .systemGreen, in: window)
        }
    }

    /// Opens Find in Files limited to a folder ("" for every scratch).
    private func findInFolder(_ id: String) {
        editor.flush { [self] in
            findInScratches.show(over: window, query: nil, location: folderURL(forId: id).standardizedFileURL.path)
        }
    }

    private func showOpenPanel() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Files open in place: changes are saved to the original file."
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.openFiles(panel.urls) }
        }
    }

    /// Opens a scratch or file (selecting it in the list when it's a scratch), optionally at a line.
    private func show(_ scratch: Scratch, line: Int? = nil) {
        window?.makeKeyAndOrderFront(nil)
        if scratch != current || isDiffing || activeTool != nil {
            sidebar.reload(store.list(), select: scratch.isListed ? scratch : nil)
            open(scratch)
        }
        if let line, line > 0, !scratch.language.isRichText {
            editor.text { [weak self] text in
                guard let self, let text else { return }
                let ns = text as NSString
                var offset = 0
                for _ in 1..<line {
                    let next = ns.range(of: "\n", range: NSRange(location: offset, length: ns.length - offset))
                    guard next.location != NSNotFound else { break }
                    offset = next.location + 1
                }
                self.editor.reveal(NSRange(location: offset, length: 0))
            }
        }
        focusEditor()
    }

    /// ⇧⌘O: IntelliJ-style "Go to File" over every scratch, opened file and folder.
    private func showGotoScratch() {
        let all = store.list()
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = Settings.shared.recentScratches.compactMap { byId[$0] }
        ordered += all.filter { !ordered.contains($0) }.sorted { $0.modified > $1.modified }
        // With an empty query the open scratch goes last: you're looking for something else.
        if let current, let index = ordered.firstIndex(of: current) { ordered.append(ordered.remove(at: index)) }
        let picker = gotoPicker
        func lineInQuery() -> Int? { FuzzyMatcher.splitLine(picker.query).line }
        var items = ordered.map { scratch in
            PaletteItem(id: "goto.\(scratch.id)", title: scratch.name,
                        category: scratch.folder.isEmpty ? (scratch == current ? "current" : "") : scratch.folder,
                        keywords: scratch.folder, icon: (scratch.language.symbolName, scratch.language.tint)) { [weak self] in
                self?.show(scratch, line: lineInQuery())
            }
        }
        items += openedFiles.map { file in
            PaletteItem(id: "goto.file.\(file.id)", title: file.name, category: Self.folderDisplay(file),
                        keywords: file.url.deletingLastPathComponent().path,
                        icon: (file.language.symbolName, file.language.tint)) { [weak self] in
                self?.show(file, line: lineInQuery())
            }
        }
        items += ScratchStore.folders().map { folder in
            PaletteItem(id: "goto.folder.\(folder.id)", title: folder.name,
                        category: folder.parent.isEmpty ? "folder" : "folder in \(folder.parent)",
                        keywords: folder.parent, icon: ("folder.fill", .systemBlue)) { [weak self] in
                guard let self else { return }
                if self.sidebarItem.isCollapsed { self.sidebarItem.animator().isCollapsed = false }
                self.sidebar.showFolder(folder.id)
            }
        }
        picker.matcher = { item, query in
            let penalty = item.id.hasPrefix("goto.folder.") ? 30 : item.id.hasPrefix("goto.file.") ? 10 : 0
            return FuzzyMatcher.match(query: FuzzyMatcher.splitLine(query).name, name: item.title, folder: item.keywords)
                .map { ($0.score - penalty, $0.positions) }
        }
        editor.flush { [self] in
            picker.show(over: window, items: items)
        }
    }

    // MARK: Go to Symbol

    /// ⌘[: the open file's outline — classes, functions, keys, headings… — fuzzy-searchable, previewed as you move.
    private func showGotoSymbol() {
        guard let scratch = current, activeTool == nil, !isDiffing else { return NSSound.beep() }
        if showsRichText {
            presentSymbols(richPage.symbols(), cursor: richPage.cursorLocation, truncated: false, in: scratch, rich: true)
        } else {
            editor.symbols { [weak self] symbols, cursor, truncated in
                self?.presentSymbols(symbols, cursor: cursor, truncated: truncated, in: scratch, rich: false)
            }
        }
    }

    private func presentSymbols(_ symbols: [DocumentSymbol], cursor: Int, truncated: Bool, in scratch: Scratch, rich: Bool) {
        guard current == scratch, activeTool == nil else { return }
        guard !symbols.isEmpty else {
            if !rich { editor.endSymbolPeek(select: nil) }
            return showMessage("No symbols in \(scratch.name)")
        }
        let items = symbols.enumerated().map { index, symbol in
            let where_ = [symbol.detail, symbol.container.isEmpty ? "" : "in \(symbol.container)", "\(symbol.line)"]
            var item = PaletteItem(id: "symbol.\(index)", title: symbol.name,
                                   category: where_.filter { !$0.isEmpty }.joined(separator: "  ·  "),
                                   keywords: symbol.container, icon: symbol.tile) { [weak self] in
                guard let self else { return }
                if rich { self.richPage.select(symbol.range) } else { self.editor.endSymbolPeek(select: symbol.range) }
            }
            item.indent = symbol.depth
            return item
        }
        let picker = symbolPicker
        picker.placeholder = truncated
            ? "Symbols in \(scratch.name) (first \(symbols.count.formatted())) — @kind filters, Class/member narrows"
            : "Symbols in \(scratch.name) — @kind filters (@method, @key…), Class/member narrows"
        // "@method get" keeps methods matching "get"; "User/save" matches save inside User.
        picker.matcher = { item, query in
            guard let index = Int(item.id.dropFirst("symbol.".count)), symbols.indices.contains(index) else { return nil }
            let symbol = symbols[index]
            var text = query
            if text.hasPrefix("@") {
                let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
                let kind = parts.first.map { $0.lowercased() } ?? ""
                guard kind.isEmpty || symbol.kindLabel.lowercased().hasPrefix(kind) || symbol.kind.lowercased().hasPrefix(kind) else { return nil }
                text = parts.count > 1 ? String(parts[1]) : ""
            }
            // Names can hold "/" themselves (OpenAPI routes "/v1/{id}/charges", "GET /pets"): match them whole first.
            if text.contains("/"), let whole = FuzzyMatcher.subsequence(text.filter { $0 != " " && $0 != "*" }.lowercased(), in: symbol.name) {
                return (whole.score, whole.positions)
            }
            return FuzzyMatcher.match(query: text, name: symbol.name, folder: symbol.container)
        }
        picker.onHighlight = { [weak self] item in
            guard let self, let index = Int(item.id.dropFirst("symbol.".count)), symbols.indices.contains(index) else { return }
            if rich { self.richPage.peek(symbols[index].range) } else { self.editor.peekSymbol(at: symbols[index].range.location) }
        }
        picker.onDismiss = { [weak self] accepted in
            if !accepted, !rich { self?.editor.endSymbolPeek(select: nil) }
        }
        // Start on the innermost symbol around the cursor, like IntelliJ's file structure.
        let initial = symbols.indices.last { symbols[$0].range.location <= cursor && cursor <= symbols[$0].end }
            ?? symbols.indices.last { symbols[$0].range.location <= cursor } ?? 0
        picker.show(over: window, items: items, initialRow: initial, cycleKey: KeymapStore.shared.key(for: "gotoSymbol"))
    }

    // MARK: Action dispatch

    /// Runs an action from one of its extra shortcuts (menus only carry the primary one); false when unavailable.
    func performShortcut(_ id: String) -> Bool {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil, isEnabled(id) else { return false }
        perform(id)
        return true
    }

    @objc func performAction(_ sender: Any?) {
        let id = ((sender as? NSMenuItem)?.representedObject as? String)
            ?? (sender as? NSToolbarItem)?.itemIdentifier.rawValue
        if let id { perform(id) }
    }

    /// Format menu actions and the rich text page command each one runs.
    private static let richFormatActions: [String: String] = [
        "formatBold": "bold", "formatItalic": "italic", "formatUnderline": "underline",
        "formatStrikethrough": "strikethrough", "formatAlignLeft": "alignLeft", "formatAlignCenter": "alignCenter",
        "formatAlignRight": "alignRight", "formatJustify": "alignJustified", "formatBulletList": "bulletList",
        "formatNumberedList": "numberedList", "formatFonts": "fonts", "formatClear": "clearFormatting",
        "formatInsertImage": "insertImage", "formatBigger": "bigger", "formatSmaller": "smaller",
    ]

    /// Editor commands for a rich text page; true when handled (or deliberately ignored).
    private func performOnRichPage(_ id: String) -> Bool {
        switch id {
        case "find": richPage.performFind(.showFindInterface)
        case "findNext": richPage.performFind(.nextMatch)
        case "findPrevious": richPage.performFind(.previousMatch)
        case "zoomIn": richPage.zoom(0.1)
        case "zoomOut": richPage.zoom(-0.1)
        case "zoomReset": richPage.zoom(nil)
        default:
            // Code-editor commands (duplicate line, multi-cursor…) have no meaning here.
            guard Actions.byId[id]?.scope == .editor else { return false }
            NSSound.beep()
        }
        return true
    }

    func perform(_ id: String) {
        if let command = Self.richFormatActions[id] {
            if showsRichText { richPage.run(command) } else { NSSound.beep() }
            return
        }
        if showsRichText, performOnRichPage(id) { return }
        let selection = sidebar.selectedScratches
        switch id {
        case "newScratch": showNewScratchMenu()
        case "gotoScratch": showGotoScratch()
        case "openFile": showOpenPanel()
        case "addExternalFolder": showAddFolderPanel()
        case "installCLI": installCommandLineTool()
        case "copyRichText": editor.copyRichText()
        case "exportPreview": showExportPopover()
        case "exportPreviewPDF": exportPreview(.pdf)
        case "exportPreviewHTML": exportPreview(.html)
        case "exportPreviewMHTML": exportPreview(.mhtml)
        case "specViewerSwagger", "specViewerScalar", "specViewerKong":
            if let viewer = SpecViewer.allCases.first(where: { $0.actionId == id }) { setSpecViewer(viewer) }
        case "newFromClipboard":
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if Curl.looksLikeCurl(text), let converted = try? Curl.toHTTP(text, indent: Settings.shared.tabSize) {
                if let scratch = createScratch(.http, content: converted + "\n") {
                    Toast.show("Created \(scratch.name) from clipboard (curl converted to HTTP)", in: window)
                }
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let scratch = createScratch(.text) {
                    Toast.show("Clipboard has no text — created empty \(scratch.name)",
                               symbol: "exclamationmark.triangle.fill", tint: .systemOrange, in: window)
                }
            } else if let scratch = createScratch(Language.detect(text), content: text) {
                if scratch.language.isTable, Settings.shared.previewMode == .off { setPreview(.split) }
                Toast.show("Created \(scratch.name) from clipboard", in: window)
            }
        case "renameScratch": beginRename()
        case "deleteScratch": if let current, current.isListed { delete([current]) }
        case "openSharedPackages": openSharedPackages()
        case "installSharedPackages": installSharedPackages()
        case "chooseJDK": showJDKMenu(from: jdkButton)
        case "copyPath": if let current { copyPath([current]) }
        case "copyFile": if let current { copyFiles([current]) }
        case "revealScratch": if let url = current?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "revealInSidebar":
            // Like IntelliJ's ⌘1: a second press, while the list has focus, hides it again.
            if sidebarHasFocus {
                sidebarItem.animator().isCollapsed = true
                focusEditor()
            } else {
                revealInSidebar()
            }
        case "editorOnly": toggleEditorOnly()
        case "compareWithClipboard": compareWithClipboard()
        case "nextScratch": step(1)
        case "previousScratch": step(-1)
        case "commandPalette": showPalette()
        case "recentScratches": showRecentScratches()
        case "navigateBack": navigate(back: true)
        case "navigateForward": navigate(back: false)
        case "save": saveNow()
        case "gotoSymbol": showGotoSymbol()
        case "closeTab":
            if activeTool != nil, current != nil {
                navigate(back: true)
            } else if activeTool != nil {
                closeTool()
                updateChrome()
            } else if let current {
                closeTabs { $0 == current }
            }
        case "closeOtherTabs": if let current { closeTabs { $0 != current } }
        case "closeAllTabs": closeTabs { _ in true }
        case "nextTab": stepTab(1)
        case "previousTab": stepTab(-1)
        case "sidebarCompare": compare(selection)
        case "sidebarCopyFile": copyFiles(selection)
        case "sidebarDelete": delete(selection)
        case "sidebarRename":
            if selection.count == 1 { sidebar.beginRename(selection[0]) }
        case "findInScratches": showFindInScratches()
        case "format": format(compact: false)
        case "compact": format(compact: true)
        case "run": run()
        case "stop": runner.stop(); http.stop()
        case "httpRunAll": runHTTP(at: nil, all: true)
        case "httpCopyCurl": copyRequestAsCurl()
        case "httpImportCurl": importCurlFromClipboard()
        case "httpOpenResponse": openLastResponse()
        case "toggleSidebar": sidebarItem.animator().isCollapsed.toggle()
        case "toggleConsole": showConsole(consoleItem.isCollapsed)
        case "toggleConsolePosition": toggleConsolePosition()
        case "clearConsole": console.clear()
        case "toggleWrap": Settings.shared.lineWrap.toggle()
        case "togglePreview":
            if current?.language == .diff { editor.exec("toggleDiffMode") } else { togglePreview(.split) }
        case "fullPreview": togglePreview(.full)
        case "groupByType": sidebar.toggleGrouping(.type)
        case "groupByDate": sidebar.toggleGrouping(.date)
        case "toggleFoldersPane": toggleFoldersPane()
        case "zoomIn", "zoomOut", "zoomReset":
            let step = id == "zoomIn" ? 1 : id == "zoomOut" ? -1 : 0
            editor.zoomPreview(step) { handled in
                guard !handled else { return }
                switch step {
                case 1: Settings.shared.fontSize += 1
                case -1: Settings.shared.fontSize -= 1
                default: Settings.shared.fontSize = Settings.defaultFontSize
                }
            }
        default:
            if Actions.byId[id]?.scope == .editor { editor.exec(id) }
        }
    }

    private static let scratchOnlyActions: Set<String> = [
        "format", "compact", "run", "togglePreview", "fullPreview", "httpRunAll", "httpCopyCurl",
        "renameScratch", "deleteScratch", "revealScratch", "copyPath", "copyFile", "compareWithClipboard",
    ]

    private func isEnabled(_ id: String) -> Bool {
        if Self.richFormatActions[id] != nil { return showsRichText }
        if showsRichText {
            if Actions.byId[id]?.scope == .editor { return ["find", "findNext", "findPrevious"].contains(id) }
            if ["toggleWrap", "compareWithClipboard"].contains(id) { return false }
        }
        if activeTool != nil || current == nil {
            if Self.scratchOnlyActions.contains(id) { return false }
            if id == "revealInSidebar" { return activeTool != nil || sidebarHasFocus }
            if activeTool == nil, Actions.byId[id]?.scope == .editor || id == "toggleWrap" { return false }
        }
        let lang = current?.language
        switch id {
        case "format": return lang?.canFormat ?? false
        case "compact": return lang?.canCompact ?? false
        case "run": return ((lang?.canRun ?? false) || current?.isSharedManifest == true) && !runner.isRunning && !http.isRunning
        case "installSharedPackages": return !runner.isRunning
        case "stop": return runner.isRunning || http.isRunning
        case "navigateBack": return canNavigate.back
        case "navigateForward": return canNavigate.forward
        case "save": return current != nil && activeTool == nil
        case "gotoSymbol": return current != nil && activeTool == nil && !isDiffing
        case "closeTab": return current != nil || activeTool != nil
        case "closeOtherTabs": return current != nil && tabs.count > 1
        case "closeAllTabs": return !tabs.isEmpty
        case "nextTab", "previousTab": return tabs.count > 1 || (activeTool != nil && !tabs.isEmpty)
        case "httpRunAll", "httpCopyCurl": return lang == .http
        case "httpOpenResponse": return http.lastResponse != nil
        case "togglePreview": return (current != nil && editor.previewAvailable) || lang == .diff
        case "fullPreview": return current != nil && editor.previewAvailable
        case "copyRichText": return lang == .markdown && activeTool == nil
        case "exportPreview", "exportPreviewHTML", "exportPreviewMHTML": return exportKind != nil
        case "exportPreviewPDF": return exportKind == "markdown"
        case "specViewerSwagger", "specViewerScalar", "specViewerKong": return exportKind == "openapi"
        case "revealInSidebar": return current?.isListed == true || sidebarHasFocus
        case "renameScratch", "deleteScratch":
            return current?.isListed ?? false
        case "revealScratch", "copyPath", "copyFile", "compareWithClipboard":
            return current != nil
        default: return true
        }
    }

    @objc func changeLanguageFromMenu(_ sender: NSMenuItem) {
        let language = Language.allCases[sender.tag]
        if language == .text, let current { explicitPlainText.insert(current.id) }
        changeLanguage(to: language)
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let (id, scratches) = sender.representedObject as? (String, [Scratch]) else { return }
        switch id {
        case "rename":
            if let s = scratches.first { sidebar.beginRename(s) }
        case "copyPath": copyPath(scratches)
        case "copyFile": copyFiles(scratches)
        case "compare": compare(scratches)
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting(scratches.map(\.url))
        case "delete": delete(scratches)
        default: break
        }
    }

    @objc private func settingsChanged() {
        if current?.language == .java { updateJDKButton() }
        editor.applySettings()
        console.updateFont()
        applyConsolePosition()
    }

    @objc private func keymapChanged() {
        editor.applyKeymap()
        updateToolbarTips()
    }

    // MARK: Lifecycle

    /// Called before quitting so the last keystrokes reach the disk.
    func flushAll() {
        runner.stop()
        http.stop()
        editor.flushSynchronously()
        store.flushWrites()
    }

    func windowDidResignKey(_ notification: Notification) {
        editor.flush {}
    }
}

// MARK: - Menu & toolbar validation

extension MainWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(changeLanguageFromMenu(_:)) {
            menuItem.state = Language.allCases[menuItem.tag] == current?.language ? .on : .off
            return current != nil
        }
        if menuItem.action == #selector(performAction(_:)), let id = menuItem.representedObject as? String {
            // A popup (Go to Symbol, Find Action…) is key: its search field gets ⌘⌫ and friends, not the editor.
            if NSApp.keyWindow is PopupPanel { return false }
            switch id {
            case "toggleWrap": menuItem.state = Settings.shared.lineWrap ? .on : .off
            case "groupByType": menuItem.state = sidebar.grouping == .type ? .on : .off
            case "groupByDate": menuItem.state = sidebar.grouping == .date ? .on : .off
            case "toggleFoldersPane": menuItem.state = sidebar.isFoldersPane ? .on : .off
            case "togglePreview": menuItem.state = Settings.shared.previewMode == .split && isEnabled(id) ? .on : .off
            case "fullPreview": menuItem.state = Settings.shared.previewMode == .full && isEnabled(id) ? .on : .off
            case "specViewerSwagger", "specViewerScalar", "specViewerKong":
                menuItem.state = Settings.shared.specViewer.actionId == id ? .on : .off
            default: break
            }
            return isEnabled(id)
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.itemIdentifier.rawValue)
    }

    var languageMenuItems: [NSMenuItem] {
        Language.allCases.enumerated().map { i, lang in
            let item = NSMenuItem(title: lang.displayName, action: #selector(changeLanguageFromMenu(_:)), keyEquivalent: "")
            item.tag = i
            item.image = NSImage(systemSymbolName: lang.symbolName, accessibilityDescription: nil)
            return item
        }
    }
}

// MARK: - Toolbar

extension MainWindowController: NSToolbarDelegate {
    /// Toolbar buttons by action id: symbol and tooltip title.
    private static let buttonSpecs: [(id: String, symbol: String, title: String)] = [
        ("toggleSidebar", "sidebar.left", "Show/Hide Sidebar"),
        ("newScratch", "plus", "New Scratch"),
        ("format", "wand.and.rays", "Reformat Code"),
        ("run", "play.fill", "Run"),
        ("stop", "stop.fill", "Stop"),
        ("copyPath", "link", "Copy File Path"),
        ("copyFile", "doc.on.doc", "Copy File"),
        ("commandPalette", "command", "Find Action / Dev Tools"),
        ("toggleConsole", "terminal", "Toggle Run Console"),
        ("openSharedPackages", "shippingbox", "Open Shared package.json"),
        ("installSharedPackages", "arrow.down.circle", "npm install (Shared Packages)"),
    ]
    private static let previewSpecs = [("doc.plaintext", "Editor only"), ("rectangle.split.2x1", "Editor and preview"),
                                       ("eye", "Preview only")]

    private func setUpToolbar() {
        for spec in Self.buttonSpecs {
            let button = ToolbarStyle.button(symbol: spec.symbol, tip: spec.title, target: self,
                                             action: #selector(toolbarButtonClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(spec.id)
            toolbarButtons[spec.id] = button
        }
        toolbarButtons["run"]?.semanticTint = .systemGreen
        toolbarButtons["stop"]?.semanticTint = .systemRed
        toolbarButtons["toggleConsole"]?.isToggle = true
        toolbarButtons["newScratch"].map { sidebar.addBarControl(ToolbarStyle.makeCompact($0)) }

        previewButtons = Self.previewSpecs.enumerated().map { i, spec in
            let button = ToolbarStyle.button(symbol: spec.0, tip: spec.1, target: self, action: #selector(previewButtonClicked(_:)))
            button.tag = i
            button.isToggle = true
            return button
        }
        languageButton.onClick = { [weak self] button in self?.showLanguageMenu(from: button) }
        jdkButton.onClick = { [weak self] button in self?.showJDKMenu(from: button) }
        viewerButton.onClick = { [weak self] button in self?.showViewerMenu(from: button) }
        editorPane.setHeaderControls([languageButton, previewGroup, viewerButton, exportButton, jdkButton, packagesGroup])
        updateToolbarTips()

        let toolbar = NSToolbar(identifier: "ScratchPad.toolbar.v4")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
        window?.toolbar = toolbar
    }

    private func updateToolbarTips() {
        let keys = KeymapStore.shared
        func tip(_ title: String, _ id: String) -> String {
            keys.key(for: id).map { "\(title) (\($0.display))" } ?? title
        }
        for spec in Self.buttonSpecs { toolbarButtons[spec.id]?.toolTip = tip(spec.title, spec.id) }
        previewButtons[safe: 0]?.toolTip = "Editor only"
        previewButtons[safe: 1]?.toolTip = tip("Editor and preview", "togglePreview")
        previewButtons[safe: 2]?.toolTip = tip("Preview only", "fullPreview")
        languageButton.toolTip = "Change the file type"
        jdkButton.setAccessibilityHelp("Choose the JDK used to run Java scratches")
    }

    @objc private func toolbarButtonClicked(_ sender: HoverButton) {
        guard let id = sender.identifier?.rawValue else { return }
        perform(id)
        updateToolbarState()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if #available(macOS 26.0, *) {
            // Spaces keep each group in a glass capsule of its own.
            return [.sidebarToggle, .sidebarTrackingSeparator, .tabs, .codeGroup, .space, .fileGroup, .space, .toolsGroup]
        }
        return [.sidebarToggle, .sidebarTrackingSeparator, .tabs, .codeGroup, .fileGroup, .toolsGroup]
    }

    private func toolbarGroup(_ ids: [String]) -> ToolbarGroup {
        let views = ids.compactMap { toolbarButtons[$0] }
        if #available(macOS 26.0, *) { return ToolbarGroup(views, bare: true) }
        return ToolbarGroup(views)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .sidebarToggle:
            item.view = toolbarButtons["toggleSidebar"]
            item.label = "Sidebar"
        case .tabs:
            // Takes all the room between the sidebar and the buttons, like a search field would.
            item.view = tabBar
            // No glass capsule behind the tabs (macOS 26 gives custom-view items one by default).
            item.isBordered = false
            item.minSize = NSSize(width: 160, height: Self.tabBarHeight)
            item.maxSize = NSSize(width: 10_000, height: Self.tabBarHeight)
            item.label = "Tabs"
        case .codeGroup:
            item.view = toolbarGroup(["format", "run", "stop"])
            item.label = "Code"
        case .fileGroup:
            item.view = toolbarGroup(["copyPath", "copyFile"])
            item.label = "File"
        case .toolsGroup:
            item.view = toolbarGroup(["commandPalette", "toggleConsole"])
            item.label = "Tools"
        default:
            return nil
        }
        return item
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Delegates

extension MainWindowController: EditorControllerDelegate {
    func editorDidBecomeReady(_ editor: EditorController) {
        // Also runs after a web content crash + reload; restore whatever is on screen.
        editor.setPreview(Settings.shared.previewMode)
        if let current, !current.language.isRichText {
            editor.load(id: current.id, text: store.read(current), language: current.language)
        }
    }

    func editor(_ editor: EditorController, didChange id: String, text: String) {
        guard let scratch = sidebar.scratches.first(where: { $0.id == id }) ?? (current?.id == id ? current : nil)
            ?? externalById[id] else { return }
        store.save(scratch, text: text)
    }

    func editor(_ editor: EditorController, status: EditorStatus) {
        editorPane.setStatus(status)
    }

    func editor(_ editor: EditorController, didPasteIntoEmpty id: String) {
        guard current?.id == id, !explicitPlainText.contains(id) else { return }
        editor.text { [self] text in
            guard let text, current?.id == id else { return }
            if Curl.looksLikeCurl(text), let converted = try? Curl.toHTTP(text, indent: Settings.shared.tabSize) {
                if current?.language != .http { changeLanguage(to: .http) }
                editor.replace([TextSelection(from: 0, to: (text as NSString).length, text: converted + "\n")])
                showMessage("Converted cURL to an HTTP request")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let detected = Language.detect(text)
                DispatchQueue.main.async { self?.applyDetected(detected, to: id) }
            }
        }
    }

    private func applyDetected(_ detected: Language, to id: String) {
        guard current?.id == id, activeTool == nil, detected != .text, detected != current?.language else { return }
        changeLanguage(to: detected)
        if detected.isTable, Settings.shared.previewMode == .off {
            setPreview(.split)
            showMessage("Detected \(detected.displayName) — showing it as a table")
        } else {
            showMessage("Detected \(detected.displayName)")
        }
    }

    func editor(_ editor: EditorController, requestsAction id: String) {
        perform(id)
    }

    func editor(_ editor: EditorController, previewModeDidChange mode: PreviewMode) {
        updatePreviewControl()
    }

    func editor(_ editor: EditorController, didPasteCurl text: String, separatorBefore: Bool, separatorAfter: Bool) {
        insertCurl(text, separatorBefore: separatorBefore, separatorAfter: separatorAfter)
    }

    func editor(_ editor: EditorController, runRequestAt offset: Int) {
        runHTTP(at: offset, all: false)
    }

    func editor(_ editor: EditorController, openResponse text: String, language: Language) {
        createScratch(language, content: text)
        showMessage("Opened response as a \(language.displayName) scratch")
    }

    func editor(_ editor: EditorController, showMessage text: String) {
        showMessage(text)
    }

    func editorDidCloseDiff(_ editor: EditorController) {
        isDiffing = false
        editorPane.setMessage("", isError: false)
    }
}

extension MainWindowController: SidebarDelegate {
    func sidebar(_ sidebar: SidebarViewController, didSelect scratch: Scratch) {
        guard scratch != current || isDiffing || activeTool != nil else { return }
        open(scratch)
    }

    func sidebar(_ sidebar: SidebarViewController, openTool id: String) {
        guard id != activeTool?.id else { return }
        editor.flush { [weak self] in self?.openTool(id) }
    }

    func sidebar(_ sidebar: SidebarViewController, rename scratch: Scratch, to name: String) {
        rename(scratch, to: name)
    }

    func sidebar(_ sidebar: SidebarViewController, perform actionId: String) {
        if actionId == "revealInSidebar" { return revealInSidebar() }
        perform(actionId)
    }

    func sidebar(_ sidebar: SidebarViewController, importFiles urls: [URL], into folder: String) {
        importFiles(urls, into: folder)
    }

    func sidebar(_ sidebar: SidebarViewController, renameFolder folder: ScratchFolder, to name: String) {
        renameFolder(folder, to: name)
    }

    func sidebar(_ sidebar: SidebarViewController, move scratches: [Scratch], folders: [ScratchFolder], to folder: String) {
        move(scratches, folders: folders, to: folder)
    }

    func sidebar(_ sidebar: SidebarViewController, addExternalFolders urls: [URL]) {
        addExternalFolders(urls)
    }

    func sidebarFolderMenu(_ sidebar: SidebarViewController, for folder: ScratchFolder?) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String? = nil, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: handler)
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        guard let folder else {
            add("New Scratch…", "square.and.pencil") { [weak self] in self?.showNewScratchMenu(in: "") }
            add("New Folder", "folder.badge.plus") { [weak self] in self?.createFolder(in: "") }
            menu.addItem(.separator())
            add("Add Folder to Sidebar…", "externaldrive.badge.plus") { [weak self] in self?.showAddFolderPanel() }
            add("Find in Files…", "magnifyingglass") { [weak self] in self?.findInFolder("") }
            return menu
        }
        add(folder.isExternal ? "New File Here…" : "New Scratch Here…", "square.and.pencil") { [weak self] in
            self?.showNewScratchMenu(in: folder.id)
        }
        add("New Folder Inside", "folder.badge.plus") { [weak self] in self?.createFolder(in: folder.id) }
        add("Find in This Folder…", "magnifyingglass") { [weak self] in self?.findInFolder(folder.id) }
        menu.addItem(.separator())
        if !folder.isExternalRoot { add("Rename…") { [weak self] in self?.sidebar.beginRename(folder) } }
        add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        add("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.url.path, forType: .string)
        }
        if folder.isExternalRoot {
            menu.addItem(.separator())
            add("Remove from Sidebar", "minus.circle") { [weak self] in self?.removeExternalFolder(folder.id) }
            return menu
        }
        let move = moveMenu(excluding: folder.parent, root: folder.storageRoot,
                            skip: { $0 == folder || folder.contains($0.id) }) { [weak self] target in
            self?.move([], folders: [folder], to: target)
        }
        if move.isEnabled { menu.addItem(move) }
        menu.addItem(.separator())
        add("Move Folder to Trash", "trash") { [weak self] in self?.deleteFolder(folder) }
        return menu
    }

    /// "Move to" submenu listing the folders of one tree (`root`: "" for the scratches folder, else an external
    /// folder) except `current`; the scratches tree also offers the top level.
    private func moveMenu(excluding current: String, root: String, skip: (ScratchFolder) -> Bool = { _ in false },
                          action: @escaping (String) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if root.isEmpty, !current.isEmpty {
            let top = ClosureMenuItem(title: "Top Level") { action("") }
            top.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            submenu.addItem(top)
            submenu.addItem(.separator())
        }
        for folder in ScratchStore.folders() where folder.storageRoot == root && folder.id != current && !skip(folder) {
            let depth = (root.isEmpty ? Substring(folder.id) : folder.id.dropFirst(root.count)).filter { $0 == "/" }.count
            let entry = ClosureMenuItem(title: folder.name) { action(folder.id) }
            entry.indentationLevel = depth
            entry.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            entry.toolTip = folder.id
            submenu.addItem(entry)
        }
        item.submenu = submenu
        item.isEnabled = !submenu.items.isEmpty
        return item
    }

    func sidebarContextMenu(_ sidebar: SidebarViewController, for scratches: [Scratch]) -> NSMenu {
        let menu = NSMenu()
        let keys = KeymapStore.shared
        func add(_ id: String, _ title: String, key action: String? = nil) {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.representedObject = (id, scratches)
            item.target = self
            if let action, let combo = keys.key(for: action) {
                (item.keyEquivalent, item.keyEquivalentModifierMask) = combo.menuEquivalent
            }
            menu.addItem(item)
        }
        if scratches.count == 1 {
            add("rename", "Rename…", key: "sidebarRename")
            let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
            let langMenu = NSMenu()
            if scratches[0] != current { open(scratches[0]) }
            for item in languageMenuItems {
                item.target = self
                langMenu.addItem(item)
            }
            langItem.submenu = langMenu
            menu.addItem(langItem)
            menu.addItem(.separator())
        }
        if scratches.count == 2 {
            add("compare", "Compare Scratches", key: "sidebarCompare")
            menu.addItem(.separator())
        }
        let sameFolder = Set(scratches.map(\.folder)).count == 1 ? scratches[0].folder : "\u{0}"
        let roots = Set(scratches.map(\.storageRoot))
        let move = moveMenu(excluding: sameFolder, root: roots.first ?? "") { [weak self] target in
            self?.move(scratches, folders: [], to: target)
        }
        if roots.count == 1, move.isEnabled {
            menu.addItem(move)
            let newFolder = ClosureMenuItem(title: "New Folder with Selection") { [weak self] in
                guard let self else { return }
                do {
                    let folder = try self.store.createFolder(in: scratches[0].folder)
                    self.move(scratches, folders: [], to: folder.id)
                    DispatchQueue.main.async { self.sidebar.beginRename(folder) }
                } catch {
                    self.presentError(error)
                }
            }
            menu.addItem(newFolder)
            menu.addItem(.separator())
        }
        add("copyFile", scratches.count == 1 ? "Copy File" : "Copy \(scratches.count) Files", key: "sidebarCopyFile")
        add("copyPath", scratches.count == 1 ? "Copy Path" : "Copy Paths", key: "copyPath")
        add("reveal", "Reveal in Finder")
        menu.addItem(.separator())
        add("delete", scratches.count == 1 ? "Move to Trash" : "Move \(scratches.count) to Trash", key: "sidebarDelete")
        return menu
    }
}

extension MainWindowController: FindInScratchesDelegate {
    func scratchesToSearch(_ controller: FindInScratchesController) -> [Scratch] {
        store.flushWrites()
        let listed = store.list()
        return listed + openedFiles.filter { !listed.contains($0) }
    }

    func findInScratches(_ controller: FindInScratchesController, open match: ScratchMatch) {
        window?.makeKeyAndOrderFront(nil)
        if match.scratch != current || isDiffing || activeTool != nil {
            sidebar.reload(store.list(), select: match.scratch.isListed ? match.scratch : nil)
            open(match.scratch)
        }
        guard current == match.scratch else { return }
        if showsRichText { richPage.reveal(match.range) } else { editor.reveal(match.range) }
        focusEditor()
    }
}

extension MainWindowController: RunnerDelegate {
    func runner(_ runner: Runner, output: String, kind: OutputKind) {
        console.append(output, kind: kind)
    }

    func runnerDidFinish(_ runner: Runner, exitCode: Int32, elapsed: TimeInterval) {
        console.setFinished(exitCode: exitCode, elapsed: elapsed)
        updateToolbarState()
    }
}

// MARK: - Editor pane (web view + status bar)

final class EditorPaneViewController: NSViewController {
    var webView: NSView!
    var tabStrip: NSView? {
        get { (view as? TabBackdropView)?.strip }
        set { _ = view; (view as? TabBackdropView)?.strip = newValue }
    }
    private let headerDivider = NSBox()
    var onPositionClick: (() -> Void)?
    var onLanguageClick: ((NSView) -> Void)?
    /// A breadcrumb was clicked: its index (the file name is last) and the view to anchor a menu to.
    var onPathClick: ((Int, NSView) -> Void)?
    private let messageIcon = NSImageView()
    private let messageLabel = NSTextField.label("", size: 11)
    private lazy var positionButton = HoverButton(title: "Ln 1, Col 1", tip: "Go to Line…", target: self,
                                                  action: #selector(positionClicked),
                                                  font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    private lazy var languageButton = HoverButton(title: "Plain Text", symbol: "doc.plaintext", tip: "Change Language",
                                                  target: self, action: #selector(languageClicked))
    private let pathStack = NSStackView()
    private let content = NSStackView()
    private var page: NSView?
    private var editorViews: [NSView] = []

    /// Shows a page (a dev tool) in place of the editor and its status bar; nil brings the editor back.
    func showPage(_ newPage: NSView?) {
        guard newPage !== page else { return }
        _ = view
        page?.removeFromSuperview()
        page = newPage
        editorViews.forEach { $0.isHidden = newPage != nil }
        guard let newPage else { return }
        newPage.translatesAutoresizingMaskIntoConstraints = false
        content.insertArrangedSubview(newPage, at: (content.arrangedSubviews.firstIndex(of: headerDivider) ?? 1) + 1)
        newPage.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        newPage.setContentHuggingPriority(.init(1), for: .vertical)
    }
    private let headerControls = NSStackView()

    /// Controls for the open file, at the trailing end of the header.
    func setHeaderControls(_ views: [NSView]) {
        views.forEach(headerControls.addArrangedSubview)
    }

    func setPath(_ location: [String], name: String) {
        pathStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !name.isEmpty else { return }
        for (index, part) in (location + [name]).enumerated() {
            let isFile = index == location.count
            if index > 0 {
                let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!)
                chevron.contentTintColor = .tertiaryLabelColor
                pathStack.addArrangedSubview(chevron)
            }
            let font = NSFont.systemFont(ofSize: 12, weight: isFile ? .medium : .regular)
            let crumb = HoverButton(title: part, tip: isFile ? "File actions" : "Show scratches in \(part)",
                                    target: self, action: #selector(crumbClicked(_:)), font: font)
            crumb.attributedTitle = NSAttributedString(string: part, attributes: [
                .font: font, .foregroundColor: isFile ? NSColor.labelColor : NSColor.secondaryLabelColor])
            crumb.tag = index
            crumb.lineBreakMode = .byTruncatingMiddle
            crumb.setContentCompressionResistancePriority(isFile ? .init(740) : .init(730), for: .horizontal)
            pathStack.addArrangedSubview(crumb)
        }
    }

    @objc private func crumbClicked(_ sender: HoverButton) { onPathClick?(sender.tag, sender) }

    override func loadView() {
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        messageIcon.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let bar = NSStackView(views: [messageIcon, messageLabel, spacer, positionButton, languageButton])
        bar.spacing = 4
        bar.setCustomSpacing(6, after: messageIcon)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let divider = NSBox()
        divider.boxType = .separator

        // Same height as the bar above the scratch list, so the dividers line up.
        pathStack.spacing = 1
        headerControls.spacing = 4
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [pathStack, headerSpacer, headerControls])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true
        headerDivider.boxType = .separator

        let stack = content
        [header, headerDivider, webView, divider, bar].forEach(stack.addArrangedSubview)
        editorViews = [webView, divider, bar]
        stack.orientation = .vertical
        stack.spacing = 0
        for v in [header, headerDivider, webView!, divider, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        webView.setContentHuggingPriority(.init(1), for: .vertical)
        stack.setHuggingPriority(.init(1), for: .vertical)
        let root = TabBackdropView()
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The window's content runs under the toolbar; keep the header below it.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    @objc private func positionClicked() { onPositionClick?() }
    @objc private func languageClicked() { onLanguageClick?(languageButton) }

    func setStatus(_ s: EditorStatus) {
        var text = "Ln \(s.line), Col \(s.column)"
        if s.cursors > 1 { text += "  ·  \(s.cursors) carets" }
        if s.selected > 0 { text += "  ·  \(s.selected) selected" }
        guard positionButton.title != text else { return }
        positionButton.title = text
        positionButton.invalidateIntrinsicContentSize()
    }

    func setLanguage(_ language: Language) {
        languageButton.title = language.displayName
        languageButton.image = NSImage(systemSymbolName: language.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        languageButton.invalidateIntrinsicContentSize()
    }

    func setMessage(_ text: String, isError: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        messageIcon.isHidden = text.isEmpty
        messageIcon.image = NSImage(systemSymbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                    accessibilityDescription: nil)
        messageIcon.contentTintColor = isError ? .systemRed : .systemGreen
    }
}

/// Shown in place of the editor once every tab is closed.
final class EmptyEditorPage: NSView {
    private static let actions = [("New Scratch", "newScratch"), ("Go to Scratch…", "gotoScratch"), ("Recent…", "recentScratches")]
    private let perform: (String) -> Void

    init(perform: @escaping (String) -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.on.square.dashed", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 40, weight: .light))!)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField.label("No Open Scratches", size: 15)
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: Self.actions.enumerated().map { index, action in
            let key = KeymapStore.shared.key(for: action.1).map { "  \($0.display)" } ?? ""
            let button = NSButton(title: action.0 + key, target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            return button
        })
        buttons.spacing = 8
        let stack = NSStackView(views: [icon, title, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked(_ sender: NSButton) { perform(Self.actions[sender.tag].1) }
}

/// The editor pane reaches up under the (transparent) toolbar; it paints the darker band the tabs sit on, ending
/// where the tabs end, so the active tab — filled like the page — reads as part of the page below it.
final class TabBackdropView: NSView {
    weak var strip: NSView? { didSet { needsDisplay = true } }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let strip, strip.window === window, window != nil else { return }
        let bottom = convert(strip.bounds, from: strip).minY
        guard bottom < bounds.maxY else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor.windowBackgroundColor.blended(withFraction: dark ? 0.38 : 0.09, of: .black)?.setFill()
        NSRect(x: 0, y: bottom, width: bounds.width, height: bounds.maxY - bottom).fill()
    }
}
