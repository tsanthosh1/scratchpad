import AppKit

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = Self("sidebarToggle")
    static let title = Self("title")
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
    /// Scratch ids visited before / after the current one, like a browser's back and forward.
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var toolbarButtons: [String: HoverButton] = [:]
    private var previewButtons: [HoverButton] = []
    private lazy var previewGroup = ToolbarGroup(previewButtons.map(ToolbarStyle.makeCompact), compact: true)
    private lazy var packagesGroup = ToolbarGroup(["openSharedPackages", "installSharedPackages"].compactMap { toolbarButtons[$0] }
        .map(ToolbarStyle.makeCompact), compact: true)
    private let titleField = TitleField()

    private(set) var current: Scratch?
    private var messageTimer: Timer?
    private var isDiffing = false
    private let toolPage = DevToolViewController()
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
    private lazy var recentPicker = CommandPaletteController(
        title: "Recent Scratches", placeholder: "Recent scratches — type to filter", empty: "No matching scratches",
        noun: ("scratch", "scratches"), verb: "Open", usesRecents: false)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "ScratchPad"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 620, height: 320)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        editor.delegate = self
        runner.delegate = self
        console.onClose = { [weak self] in self?.showConsole(false) }
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
        titleField.onRename = { [weak self] name in self?.renameCurrent(to: name) }

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = Settings.shared.foldersPane ? 720 : 420
        sidebarItem.canCollapse = true

        innerSplit.splitView.isVertical = false
        innerSplit.splitView.dividerStyle = .thin
        let editorItem = NSSplitViewItem(viewController: editorPane)
        editorItem.holdingPriority = .defaultLow
        consoleItem = NSSplitViewItem(viewController: console)
        consoleItem.canCollapse = true
        consoleItem.minimumThickness = 80
        consoleItem.holdingPriority = .init(260)
        innerSplit.addSplitViewItem(editorItem)
        innerSplit.addSplitViewItem(consoleItem)
        consoleItem.isCollapsed = true

        outerSplit.addSplitViewItem(sidebarItem)
        outerSplit.addSplitViewItem(NSSplitViewItem(viewController: innerSplit))
        outerSplit.splitView.autosaveName = "ScratchPad.outerSplit"
        window.contentViewController = outerSplit

        setUpToolbar()
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("ScratchPad.MainWindow")

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keymapChanged), name: .keymapChanged, object: nil)

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
        let last = all.first { $0.id == Settings.shared.lastScratch } ?? all.first
        sidebar.reload(all, select: last)
        if let last { open(last) }
    }

    private func refreshList(select: Scratch?) {
        sidebar.reload(store.list(), select: select)
    }

    /// Files were added, removed or renamed in the scratch folder (possibly outside the app).
    private func scratchFolderChanged() {
        let all = store.list()
        sidebar.refresh(all)
        guard let current, current.isInScratchFolder, !all.contains(current) else { return }
        // The open scratch was deleted or renamed elsewhere; move on to another one.
        editor.forget(id: current.id)
        self.current = nil
        var remaining = all
        if remaining.isEmpty, let created = try? store.create(language: .text) { remaining = [created] }
        if let next = remaining.first {
            sidebar.reload(remaining, select: next)
            open(next)
        }
    }

    private func open(_ scratch: Scratch, recordHistory: Bool = true) {
        if activeTool != nil { closeTool() }
        if recordHistory, let previous = current, previous != scratch, previous.isInScratchFolder {
            backStack.append(previous.id)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        current = scratch
        isDiffing = false
        if scratch.isInScratchFolder {
            Settings.shared.lastScratch = scratch.id
            Settings.shared.recentScratches = [scratch.id] + Settings.shared.recentScratches.filter { $0 != scratch.id }
        }
        editor.load(id: scratch.id, text: store.read(scratch), language: scratch.language)
        updateChrome()
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
        editorPane.showPage(nil)
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
        titleField.isRenamable = activeTool == nil
        if let tool = activeTool {
            window?.title = tool.title
            titleField.show(tool.title)
            titleField.toolTip = tool.summary
            editorPane.setPath(["Dev Tools"], name: tool.title)
            for control in [languageButton, previewGroup, jdkButton, packagesGroup] as [NSView] { control.isHidden = true }
            updateToolbarState()
            return
        }
        languageButton.isHidden = false
        guard let current else { return }
        window?.title = current.name
        titleField.show(current.name)
        titleField.toolTip = current.isInScratchFolder ? "\(current.url.path)\nDouble-click to rename" : current.url.path
        languageButton.show(current.language)
        editorPane.setLanguage(current.language)
        updatePreviewControl()
        jdkButton.isHidden = current.language != .java
        packagesGroup.isHidden = ![.javascript, .typescript].contains(current.language) && !current.isSharedManifest
        let location = current.isSharedManifest ? ["Shared Packages"]
            : current.isInScratchFolder ? ["Scratches"] + current.folder.split(separator: "/").map(String.init)
            : [(current.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath]
        editorPane.setPath(location, name: current.name)
        sidebar.setSharedPackagesActive(current.isSharedManifest)
        if current.language == .java { updateJDKButton() }
        updateToolbarState()
    }

    private static var javaTemplate: String {
        let indent = String(repeating: " ", count: Settings.shared.tabSize)
        return "public class Main {\n\(indent)public static void main(String[] args) {\n\(indent)\(indent)System.out.println(\"Hello\");\n\(indent)}\n}\n"
    }

    /// Folder for new scratches: what's selected in the list, else the open scratch's folder.
    private var newScratchFolder: String {
        sidebar.targetFolder ?? (current?.isInScratchFolder == true ? current!.folder : "")
    }

    @discardableResult
    private func createScratch(_ language: Language, content: String = "", in folder: String? = nil) -> Scratch? {
        do {
            let initial = !content.isEmpty ? content : language == .http ? HTTPFile.template
                : language == .diff ? DiffFile.template : language == .java ? Self.javaTemplate : content
            let scratch = try store.create(language: language, content: initial, in: folder ?? newScratchFolder)
            if language != .text { Settings.shared.lastLanguage = language }
            refreshList(select: scratch)
            open(scratch)
            return scratch
        } catch {
            presentError(error)
            return nil
        }
    }

    private func replaceCurrent(with updated: Scratch, from old: Scratch) {
        editor.rename(from: old.id, to: updated.id)
        current = updated
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
                editor.setLanguage(language)
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Rename & delete

    /// Inline rename in the toolbar title when it's visible, otherwise a small sheet.
    private func beginRename() {
        guard let current, current.isInScratchFolder else { return }
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

    /// ⌘⇧← / ⌘⇧→: walks the visit history, skipping scratches that no longer exist.
    private func navigate(back: Bool) {
        // Back from a tool page returns to the scratch underneath it.
        if back, activeTool != nil, let current {
            open(current, recordHistory: false)
            return editor.focus()
        }
        let byId = Dictionary(store.list().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        while let id = back ? backStack.popLast() : forwardStack.popLast() {
            guard let target = byId[id], target != current else { continue }
            if let current, current.isInScratchFolder {
                if back { forwardStack.append(current.id) } else { backStack.append(current.id) }
            }
            editor.flush { [self] in
                sidebar.reload(store.list(), select: target)
                open(target, recordHistory: false)
                editor.focus()
            }
            return
        }
        NSSound.beep()
    }

    private func remapHistory(_ transform: (String) -> String?) {
        backStack = backStack.map { transform($0) ?? $0 }
        forwardStack = forwardStack.map { transform($0) ?? $0 }
    }

    /// Keeps the editor cache, the open scratch and the recent list pointing at a scratch that moved on disk.
    private func relocated(_ old: Scratch, to new: Scratch) {
        guard old != new else { return }
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
    }

    /// Same as `relocated` for everything inside a folder that was renamed or moved.
    private func relocatedFolder(from old: String, to new: String) {
        guard old != new else { return }
        func remap(_ id: String) -> String? { id.hasPrefix(old + "/") ? new + id.dropFirst(old.count) : nil }
        if let current, let id = remap(current.id) {
            relocated(current, to: Scratch(url: AppPaths.scratches.appendingPathComponent(id)))
        }
        Settings.shared.recentScratches = Settings.shared.recentScratches.map { remap($0) ?? $0 }
        remapHistory(remap)
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
            : "It contains \(count == 1 ? "1 scratch" : "\(count) scratches"). You can restore it from the Trash."
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
            if let current, folder.contains(current.id) {
                editor.forget(id: current.id)
                self.current = nil
                var remaining = store.list()
                if remaining.isEmpty, let created = try? store.create(language: .text) { remaining = [created] }
                sidebar.reload(remaining, select: remaining.first)
                if let next = remaining.first { open(next) }
            } else {
                refreshList(select: current)
            }
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
        let stem = (scratch.name as NSString).deletingPathExtension
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
            let order = sidebar.orderedScratches
            let nextCandidate = order.first { !scratches.contains($0) && order.firstIndex(of: $0)! > (order.firstIndex(of: scratches[0]) ?? 0) }
                ?? order.last { !scratches.contains($0) }
            for scratch in scratches {
                do {
                    try store.delete(scratch)
                    editor.forget(id: scratch.id)
                } catch {
                    presentError(error)
                }
            }
            var remaining = store.list()
            if remaining.isEmpty, let created = try? store.create(language: .text) { remaining = [created] }
            if let current, scratches.contains(current) {
                self.current = nil
                let next = nextCandidate.flatMap { remaining.contains($0) ? $0 : nil } ?? remaining.first
                sidebar.reload(remaining, select: next)
                if let next { open(next) }
            } else {
                sidebar.reload(remaining, select: current)
            }
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
        } else if !current.isInScratchFolder {
            if index == 0 {
                menu = NSMenu()
                menu.addItem(finderItem(current.url.deletingLastPathComponent()))
            } else {
                menu = fileMenu(for: current)
            }
        } else {
            let parts = current.folder.split(separator: "/").map(String.init)
            menu = index > parts.count ? fileMenu(for: current) : folderMenu(parts.prefix(index).joined(separator: "/"))
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
        let url = id.isEmpty ? AppPaths.scratches : AppPaths.scratches.appendingPathComponent(id)
        menu.addItem(finderItem(url))

        let subfolders = ScratchStore.folders().filter { $0.parent == id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let scratches = sidebar.scratches.filter { $0.isInScratchFolder && $0.folder == id }
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
        if scratch.isInScratchFolder { ids.insert("renameScratch", at: 0) }
        for id in ids where isEnabled(id) {
            guard let title = Actions.byId[id]?.title else { continue }
            let item = ClosureMenuItem(title: title) { [weak self] in self?.perform(id) }
            if let key = KeymapStore.shared.key(for: id) { item.toolTip = key.display }
            menu.addItem(item)
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
                editor.focus()
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
        guard current?.language.canPreview == true else {
            showMessage("Preview is available for Markdown and HTML scratches", isError: true)
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
        let visible = current?.language.canPreview ?? false
        previewGroup.isHidden = !visible
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
        if show, innerSplit.splitView.subviews.count == 2, console.view.frame.height < 120 {
            let total = innerSplit.splitView.bounds.height
            innerSplit.splitView.setPosition(max(total * 0.3, min(180, total * 0.5)), ofDividerAt: 0)
        }
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
                self.editor.focus()
            }
        }
        let tools = DevTools.all.map { tool in
            PaletteItem(id: "tool.\(tool.id)", title: tool.title, category: "Dev Tools · \(tool.summary)",
                        keywords: tool.keywords, icon: (tool.symbol, tool.tint)) { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
                self?.editor.flush { self?.openTool(tool.id) }
            }
        }
        let items = scratchItems + tools
        let initial = ordered.first == current && ordered.count > 1 ? 1 : 0
        editor.flush { [self] in
            recentPicker.show(over: window, items: items, initialRow: initial,
                              cycleKey: KeymapStore.shared.key(for: "recentScratches"))
        }
    }

    private func apply(_ transform: TextTransform) {
        window?.makeKeyAndOrderFront(nil)
        editor.focus()
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

    // MARK: Action dispatch

    @objc func performAction(_ sender: Any?) {
        let id = ((sender as? NSMenuItem)?.representedObject as? String)
            ?? (sender as? NSToolbarItem)?.itemIdentifier.rawValue
        if let id { perform(id) }
    }

    func perform(_ id: String) {
        let selection = sidebar.selectedScratches
        switch id {
        case "newScratch": showNewScratchMenu()
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
                Toast.show("Created \(scratch.name) from clipboard", in: window)
            }
        case "renameScratch": beginRename()
        case "deleteScratch": if let current, current.isInScratchFolder { delete([current]) }
        case "openSharedPackages": openSharedPackages()
        case "installSharedPackages": installSharedPackages()
        case "chooseJDK": showJDKMenu(from: jdkButton)
        case "copyPath": if let current { copyPath([current]) }
        case "copyFile": if let current { copyFiles([current]) }
        case "revealScratch": if let url = current?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "revealInSidebar": revealInSidebar()
        case "compareWithClipboard": compareWithClipboard()
        case "nextScratch": step(1)
        case "previousScratch": step(-1)
        case "commandPalette": showPalette()
        case "recentScratches": showRecentScratches()
        case "navigateBack": navigate(back: true)
        case "navigateForward": navigate(back: false)
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
        case "clearConsole": console.clear()
        case "toggleWrap": Settings.shared.lineWrap.toggle()
        case "togglePreview":
            if current?.language == .diff { editor.exec("toggleDiffMode") } else { togglePreview(.split) }
        case "fullPreview": togglePreview(.full)
        case "groupByType": sidebar.toggleGrouping(.type)
        case "groupByDate": sidebar.toggleGrouping(.date)
        case "toggleFoldersPane": toggleFoldersPane()
        case "zoomIn": Settings.shared.fontSize += 1
        case "zoomOut": Settings.shared.fontSize -= 1
        case "zoomReset": Settings.shared.fontSize = Settings.defaultFontSize
        default:
            if Actions.byId[id]?.scope == .editor { editor.exec(id) }
        }
    }

    private static let scratchOnlyActions: Set<String> = [
        "format", "compact", "run", "togglePreview", "fullPreview", "httpRunAll", "httpCopyCurl",
        "renameScratch", "deleteScratch", "revealScratch", "copyPath", "copyFile", "compareWithClipboard",
    ]

    private func isEnabled(_ id: String) -> Bool {
        if activeTool != nil {
            if Self.scratchOnlyActions.contains(id) { return false }
            if id == "revealInSidebar" || id == "navigateBack" { return true }
        }
        let lang = current?.language
        switch id {
        case "format": return lang?.canFormat ?? false
        case "compact": return lang?.canCompact ?? false
        case "run": return ((lang?.canRun ?? false) || current?.isSharedManifest == true) && !runner.isRunning && !http.isRunning
        case "installSharedPackages": return !runner.isRunning
        case "stop": return runner.isRunning || http.isRunning
        case "navigateBack": return !backStack.isEmpty
        case "navigateForward": return !forwardStack.isEmpty
        case "httpRunAll", "httpCopyCurl": return lang == .http
        case "httpOpenResponse": return http.lastResponse != nil
        case "togglePreview": return (lang?.canPreview ?? false) || lang == .diff
        case "fullPreview": return lang?.canPreview ?? false
        case "renameScratch", "revealInSidebar", "deleteScratch":
            return current?.isInScratchFolder ?? false
        case "revealScratch", "copyPath", "copyFile", "compareWithClipboard":
            return current != nil
        default: return true
        }
    }

    @objc func changeLanguageFromMenu(_ sender: NSMenuItem) {
        changeLanguage(to: Language.allCases[sender.tag])
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
            switch id {
            case "toggleWrap": menuItem.state = Settings.shared.lineWrap ? .on : .off
            case "groupByType": menuItem.state = sidebar.grouping == .type ? .on : .off
            case "groupByDate": menuItem.state = sidebar.grouping == .date ? .on : .off
            case "toggleFoldersPane": menuItem.state = sidebar.isFoldersPane ? .on : .off
            case "togglePreview": menuItem.state = Settings.shared.previewMode == .split && isEnabled(id) ? .on : .off
            case "fullPreview": menuItem.state = Settings.shared.previewMode == .full && isEnabled(id) ? .on : .off
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
        editorPane.setHeaderControls([languageButton, previewGroup, jdkButton, packagesGroup])
        updateToolbarTips()

        let toolbar = NSToolbar(identifier: "ScratchPad.toolbar.v3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
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
        [.sidebarToggle, .sidebarTrackingSeparator, .title, .flexibleSpace, .codeGroup, .fileGroup, .toolsGroup]
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
        case .title:
            item.view = titleField
            item.label = "File"
        case .codeGroup:
            item.view = ToolbarGroup(["format", "run", "stop"].compactMap { toolbarButtons[$0] })
            item.label = "Code"
        case .fileGroup:
            item.view = ToolbarGroup(["copyPath", "copyFile"].compactMap { toolbarButtons[$0] })
            item.label = "File"
        case .toolsGroup:
            item.view = ToolbarGroup(["commandPalette", "toggleConsole"].compactMap { toolbarButtons[$0] })
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
        if let current { editor.load(id: current.id, text: store.read(current), language: current.language) }
    }

    func editor(_ editor: EditorController, didChange id: String, text: String) {
        guard let scratch = sidebar.scratches.first(where: { $0.id == id }) ?? (current?.id == id ? current : nil) else { return }
        store.save(scratch, text: text)
    }

    func editor(_ editor: EditorController, status: EditorStatus) {
        editorPane.setStatus(status)
    }

    func editor(_ editor: EditorController, didPasteIntoEmpty id: String) {
        guard current?.id == id else { return }
        editor.text { [self] text in
            guard let text, current?.id == id else { return }
            if Curl.looksLikeCurl(text), let converted = try? Curl.toHTTP(text, indent: Settings.shared.tabSize) {
                if current?.language != .http { changeLanguage(to: .http) }
                editor.replace([TextSelection(from: 0, to: (text as NSString).length, text: converted + "\n")])
                showMessage("Converted cURL to an HTTP request")
                return
            }
            let detected = Language.detect(text)
            if detected != .text, detected != current?.language {
                changeLanguage(to: detected)
                showMessage("Detected \(detected.displayName)")
            }
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
            return menu
        }
        add("New Scratch Here…", "square.and.pencil") { [weak self] in self?.showNewScratchMenu(in: folder.id) }
        add("New Folder Inside", "folder.badge.plus") { [weak self] in self?.createFolder(in: folder.id) }
        menu.addItem(.separator())
        add("Rename…") { [weak self] in self?.sidebar.beginRename(folder) }
        add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        add("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.url.path, forType: .string)
        }
        if !folder.parent.isEmpty || !ScratchStore.folders().filter({ $0 != folder && !folder.contains($0.id) }).isEmpty {
            menu.addItem(moveMenu(excluding: folder.parent, skip: { $0 == folder || folder.contains($0.id) }) { [weak self] target in
                self?.move([], folders: [folder], to: target)
            })
        }
        menu.addItem(.separator())
        add("Move Folder to Trash", "trash") { [weak self] in self?.deleteFolder(folder) }
        return menu
    }

    /// "Move to" submenu listing the top level and every folder except `current`.
    private func moveMenu(excluding current: String, skip: (ScratchFolder) -> Bool = { _ in false },
                          action: @escaping (String) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if !current.isEmpty {
            let top = ClosureMenuItem(title: "Top Level") { action("") }
            top.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            submenu.addItem(top)
            submenu.addItem(.separator())
        }
        for folder in ScratchStore.folders() where folder.id != current && !skip(folder) {
            let depth = folder.id.filter { $0 == "/" }.count
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
        let hasTargets = sameFolder != "" || !ScratchStore.folders().isEmpty
        if hasTargets {
            menu.addItem(moveMenu(excluding: sameFolder) { [weak self] target in self?.move(scratches, folders: [], to: target) })
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
        return store.list()
    }

    func findInScratches(_ controller: FindInScratchesController, open match: ScratchMatch) {
        window?.makeKeyAndOrderFront(nil)
        if match.scratch != current || isDiffing {
            sidebar.reload(store.list(), select: match.scratch)
            open(match.scratch)
        }
        editor.reveal(match.range)
        editor.focus()
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
        content.insertArrangedSubview(newPage, at: 2)
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
        let headerDivider = NSBox()
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
        let root = NSView()
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
