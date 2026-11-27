import AppKit

final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let general = NSTabViewItem(viewController: GeneralSettingsViewController())
        general.label = "General"
        general.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let keymap = NSTabViewItem(viewController: KeymapSettingsViewController())
        keymap.label = "Keymap"
        keymap.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(keymap)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.setContentSize(NSSize(width: 640, height: 480))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - General

private final class GeneralSettingsViewController: NSViewController {
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let tabPopup = NSPopUpButton()
    private let wrapCheck = NSButton(checkboxWithTitle: "Soft-wrap long lines", target: nil, action: nil)
    private let completeCheck = NSButton(checkboxWithTitle: "Show completions while typing (⌃Space any time)", target: nil, action: nil)
    private let jdkPopup = NSPopUpButton()
    private let nodeField = NSTextField()
    private let packagesField = NSTextField()
    private var jdks: [JDK] = []

    override func loadView() {
        let s = Settings.shared

        let monospaced = NSFontManager.shared.availableFontFamilies.filter {
            NSFont(name: $0, size: 12)?.isFixedPitch ?? false
        }
        fontPopup.addItems(withTitles: monospaced.isEmpty ? ["Menlo"] : monospaced)
        fontPopup.selectItem(withTitle: s.fontFamily)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)

        sizeStepper.minValue = 8
        sizeStepper.maxValue = 40
        sizeStepper.integerValue = s.fontSize
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped)
        sizeField.integerValue = s.fontSize
        sizeField.target = self
        sizeField.action = #selector(sizeTyped)
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let sizeRow = NSStackView(views: [sizeField, sizeStepper])

        for n in [2, 4, 8] {
            tabPopup.addItem(withTitle: "\(n) spaces")
            tabPopup.lastItem?.tag = n
        }
        tabPopup.selectItem(withTag: s.tabSize)
        tabPopup.target = self
        tabPopup.action = #selector(tabChanged)

        wrapCheck.state = s.lineWrap ? .on : .off
        wrapCheck.target = self
        wrapCheck.action = #selector(wrapChanged)
        completeCheck.state = s.autoComplete ? .on : .off
        completeCheck.target = self
        completeCheck.action = #selector(completeChanged)

        jdkPopup.target = self
        jdkPopup.action = #selector(jdkChanged)
        reloadJDKs()
        let jdkHint = hint("Java scratches run as `java Name.java` (single-file source launch, Java 11+).")

        nodeField.placeholderString = "Auto-detect"
        nodeField.stringValue = s.nodePath
        nodeField.target = self
        nodeField.action = #selector(nodeChanged)
        let nodeBrowse = NSButton(title: "Choose…", target: self, action: #selector(chooseNode))
        let nodeRow = NSStackView(views: [nodeField, nodeBrowse])
        nodeField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let nodeHint = hint("Detecting…")
        DispatchQueue.global().async {
            let detected = Toolchains.resolveNode()
            DispatchQueue.main.async {
                nodeHint.stringValue = detected.map { "Using \($0)" }
                    ?? "Node.js not found, JavaScript runs in the built-in JavaScriptCore."
            }
        }

        packagesField.placeholderString = (AppPaths.packages.path as NSString).abbreviatingWithTildeInPath
        packagesField.stringValue = s.nodePackagesDir
        packagesField.target = self
        packagesField.action = #selector(packagesChanged)
        let packagesBrowse = NSButton(title: "Choose…", target: self, action: #selector(choosePackages))
        let packagesRow = NSStackView(views: [packagesField, packagesBrowse])
        packagesField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let packagesHint = hint("Folder with the shared package.json. JavaScript and TypeScript scratches can "
            + "require/import anything installed in its node_modules. Leave empty for ScratchPad's own folder; "
            + "edit it with Code › Open Shared package.json.")

        let folder = NSButton(title: "Show Scratches in Finder", target: self, action: #selector(showFolder))

        let grid = NSGridView(views: [
            [label("Editor font:"), fontPopup],
            [label("Font size:"), sizeRow],
            [label("Indent:"), tabPopup],
            [NSGridCell.emptyContentView, wrapCheck],
            [NSGridCell.emptyContentView, completeCheck],
            [label("Java (JDK):"), jdkPopup],
            [NSGridCell.emptyContentView, jdkHint],
            [label("Node.js:"), nodeRow],
            [NSGridCell.emptyContentView, nodeHint],
            [label("Node packages:"), packagesRow],
            [NSGridCell.emptyContentView, packagesHint],
            [label("Storage:"), folder],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 5).topPadding = 12
        grid.row(at: 11).topPadding = 12

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
        ])
        view = container
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 380
        return l
    }

    private func reloadJDKs() {
        jdks = Toolchains.installedJDKs()
        jdkPopup.removeAllItems()
        for (i, jdk) in jdks.enumerated() {
            jdkPopup.addItem(withTitle: "\(jdk.name) — \(jdk.version)")
            jdkPopup.lastItem?.tag = i
            jdkPopup.lastItem?.toolTip = jdk.home
        }
        let custom = Settings.shared.javaHome
        if !custom.isEmpty, !jdks.contains(where: { $0.home == custom }) {
            jdkPopup.addItem(withTitle: (custom as NSString).abbreviatingWithTildeInPath)
            jdkPopup.lastItem?.tag = -2
        }
        jdkPopup.menu?.addItem(.separator())
        jdkPopup.addItem(withTitle: "Other JDK…")
        jdkPopup.lastItem?.tag = -1

        if let active = Toolchains.resolveJDK(), let i = jdks.firstIndex(of: active) {
            jdkPopup.selectItem(withTag: i)
        } else if !custom.isEmpty {
            jdkPopup.selectItem(withTag: -2)
        }
    }

    @objc private func fontChanged() {
        if let title = fontPopup.titleOfSelectedItem { Settings.shared.fontFamily = title }
    }

    @objc private func sizeStepped() {
        Settings.shared.fontSize = sizeStepper.integerValue
        sizeField.integerValue = Settings.shared.fontSize
    }

    @objc private func sizeTyped() {
        Settings.shared.fontSize = sizeField.integerValue
        sizeField.integerValue = Settings.shared.fontSize
        sizeStepper.integerValue = Settings.shared.fontSize
    }

    @objc private func tabChanged() {
        Settings.shared.tabSize = tabPopup.selectedTag()
    }

    @objc private func wrapChanged() {
        Settings.shared.lineWrap = wrapCheck.state == .on
    }

    @objc private func completeChanged() {
        Settings.shared.autoComplete = completeCheck.state == .on
    }

    @objc private func jdkChanged() {
        let tag = jdkPopup.selectedTag()
        if tag >= 0 {
            let jdk = jdks[tag]
            Settings.shared.javaHome = jdk.home
            Settings.shared.javaVersion = jdk.majorVersion
        } else if tag == -1 {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Choose a JDK home (the folder containing bin/java)"
            if panel.runModal() == .OK, let url = panel.url {
                var home = url.path
                if FileManager.default.isExecutableFile(atPath: home + "/Contents/Home/bin/java") {
                    home += "/Contents/Home"
                }
                if FileManager.default.isExecutableFile(atPath: home + "/bin/java") {
                    Settings.shared.javaHome = home
                } else {
                    NSSound.beep()
                }
            }
            reloadJDKs()
        }
    }

    @objc private func nodeChanged() {
        Settings.shared.nodePath = nodeField.stringValue.trimmingCharacters(in: .whitespaces)
        Toolchains.invalidateNodeCache()
    }

    @objc private func chooseNode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "Choose the node executable"
        if panel.runModal() == .OK, let url = panel.url {
            nodeField.stringValue = url.path
            nodeChanged()
        }
    }

    @objc private func packagesChanged() {
        Settings.shared.nodePackagesDir = packagesField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func choosePackages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the folder containing your shared package.json"
        if panel.runModal() == .OK, let url = panel.url {
            packagesField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            packagesChanged()
        }
    }

    @objc private func showFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.scratches])
    }
}

// MARK: - Keymap

private final class KeymapSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private var rows: [ActionDef] = Actions.all

    override func loadView() {
        search.placeholderString = "Search actions or shortcuts"
        search.delegate = self

        for (id, title, width) in [("action", "Action", 280.0), ("category", "Category", 90.0), ("shortcut", "Shortcut", 180.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(changeShortcut)
        table.target = self
        table.style = .inset

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let change = NSButton(title: "Change…", target: self, action: #selector(changeShortcut))
        let add = NSButton(title: "Add Shortcut…", target: self, action: #selector(addShortcut))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeShortcut))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        let resetAll = NSButton(title: "Reset All", target: self, action: #selector(resetAll))
        let openFile = NSButton(title: "Open keymap.json", target: self, action: #selector(openKeymapFile))
        let buttons = NSStackView(views: [change, add, remove, reset, NSView(), openFile, resetAll])

        let hint = NSTextField(wrappingLabelWithString:
            "Double-click an action to record a new shortcut, or use Add Shortcut… to give it another one. "
                + "The first shortcut is shown in menus. Customised shortcuts are shown in bold and stored in keymap.json.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [search, scroll, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [search, scroll, buttons, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        view = stack

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .keymapChanged, object: nil)
    }

    @objc private func reload() {
        let q = search.stringValue.lowercased()
        rows = q.isEmpty ? Actions.all : Actions.all.filter {
            $0.title.lowercased().contains(q) || $0.category.lowercased().contains(q)
                || KeymapStore.shared.keys(for: $0.id).contains {
                    $0.display.lowercased().contains(q) || $0.string.lowercased().contains(q)
                }
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let action = rows[row]
        let text: String
        switch column?.identifier.rawValue {
        case "action": text = action.title
        case "category": text = action.category
        default:
            let keys = KeymapStore.shared.keys(for: action.id)
            text = keys.isEmpty ? "—" : keys.map(\.display).joined(separator: ",  ")
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        if column?.identifier.rawValue == "shortcut" {
            let custom = KeymapStore.shared.isCustomized(action.id)
            field.font = custom ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        } else if column?.identifier.rawValue == "category" {
            field.textColor = .secondaryLabelColor
        }
        return field
    }

    private var selected: ActionDef? {
        table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil
    }

    @objc private func changeShortcut() {
        guard let action = selected, let window = view.window else { return }
        let sheet = ShortcutRecorderSheet(action: action, adding: false)
        window.beginSheet(sheet.window!) { _ in _ = sheet }
    }

    @objc private func addShortcut() {
        guard let action = selected, let window = view.window else { return }
        let sheet = ShortcutRecorderSheet(action: action, adding: true)
        window.beginSheet(sheet.window!) { _ in _ = sheet }
    }

    @objc private func removeShortcut() {
        guard let action = selected else { return }
        KeymapStore.shared.set(nil, for: action.id)
    }

    @objc private func resetShortcut() {
        guard let action = selected else { return }
        KeymapStore.shared.reset(action.id)
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all shortcuts to their defaults?"
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { KeymapStore.shared.resetAll() }
        }
    }

    @objc private func openKeymapFile() {
        let store = KeymapStore.shared
        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            try? "{\n}\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(store.fileURL)
    }
}

// MARK: - Recorder

private final class ShortcutRecorderSheet: NSWindowController {
    private let action: ActionDef
    /// Adds a shortcut instead of replacing the existing ones.
    private let adding: Bool
    private let recorder = RecorderView()
    private let conflictLabel = NSTextField(wrappingLabelWithString: "")
    private var combo: KeyCombo?

    init(action: ActionDef, adding: Bool) {
        self.action = action
        self.adding = adding
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        combo = adding ? nil : KeymapStore.shared.key(for: action.id)

        let title = NSTextField(labelWithString: adding ? "Press another shortcut for “\(action.title)”"
                                    : "Press the new shortcut for “\(action.title)”")
        title.font = .boldSystemFont(ofSize: 13)
        recorder.onRecord = { [weak self] in self?.recorded($0) }
        recorder.combo = combo
        conflictLabel.textColor = .systemOrange
        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.preferredMaxLayoutWidth = 360

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = ""
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        let buttons = NSStackView(views: [clear, NSView(), cancel, save])

        let stack = NSStackView(views: [title, recorder, conflictLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [recorder, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        recorder.heightAnchor.constraint(equalToConstant: 36).isActive = true
        panel.contentView = stack
        panel.initialFirstResponder = recorder
        updateConflicts()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func recorded(_ combo: KeyCombo) {
        self.combo = combo
        recorder.combo = combo
        updateConflicts()
    }

    private func updateConflicts() {
        guard let combo else {
            conflictLabel.stringValue = ""
            return
        }
        let others = KeymapStore.shared.conflicts(for: combo, excluding: action.id)
        conflictLabel.stringValue = others.isEmpty ? "" :
            "Also bound to: " + others.map(\.title).joined(separator: ", ") + ". Saving will remove it from those actions."
    }

    private func close(saving: Bool) {
        if saving {
            if let combo {
                for other in KeymapStore.shared.conflicts(for: combo, excluding: action.id) {
                    KeymapStore.shared.remove(combo, from: other.id)
                }
            }
            if adding {
                if let combo { KeymapStore.shared.add(combo, for: action.id) }
            } else {
                KeymapStore.shared.set(combo, for: action.id)
            }
        }
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    @objc private func cancel() { close(saving: false) }
    @objc private func save() { close(saving: true) }
    @objc private func clear() {
        combo = nil
        recorder.combo = nil
        updateConflicts()
    }
}

/// Captures the next key press, including ⌘ combinations that would otherwise trigger menu items.
private final class RecorderView: NSView {
    var onRecord: ((KeyCombo) -> Void)?
    var combo: KeyCombo? { didSet { needsDisplay = true } }
    private var liveModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        liveModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        needsDisplay = true
    }

    private func record(_ event: NSEvent) {
        guard let combo = KeyCombo(event: event) else { return }
        liveModifiers = []
        onRecord?(combo)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = focused ? 2 : 1
        path.stroke()

        var text: String
        if !liveModifiers.isEmpty {
            text = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { liveModifiers.contains($0.0) }.map(\.1).joined() + "…"
        } else {
            text = combo?.display ?? "No shortcut"
        }
        if let combo, liveModifiers.isEmpty { text += "    (\(combo.string))" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: combo == nil && liveModifiers.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
