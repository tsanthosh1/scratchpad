import AppKit

struct PaletteItem {
    let id: String
    let title: String
    let category: String
    var shortcut: String?
    var keywords: String = ""
    var icon: (symbol: String, tint: NSColor)?
    let run: () -> Void

    /// Icon and colour for the row's tile.
    var tile: (symbol: String, tint: NSColor) {
        if let icon { return icon }
        if id.hasPrefix("language.") || id.hasPrefix("new."),
           let lang = Language(rawValue: String(id.split(separator: ".").last ?? "")) {
            return (lang.symbolName, lang.tint)
        }
        switch category {
        case "Encode": return ("lock", .systemBlue)
        case "Decode": return ("lock.open", .systemTeal)
        case "Hash": return ("number", .systemPurple)
        case "Case": return ("textformat", .systemPink)
        case "Lines": return ("list.bullet", .systemOrange)
        case "Text": return ("text.quote", .systemIndigo)
        case "Time": return ("clock", .systemYellow)
        case "Insert": return ("plus.square.on.square", .systemGreen)
        case "Scratch", "Scratch List": return ("doc", .systemBlue)
        case "Code": return ("curlybraces", .systemOrange)
        case "HTTP": return ("network", .systemGreen)
        case "Selection": return ("cursorarrow.rays", .systemPurple)
        case "Find": return ("magnifyingglass", .systemTeal)
        case "Folding": return ("rectangle.compress.vertical", .systemGray)
        case "View": return ("eye", .systemIndigo)
        default: return ("command", .systemGray)
        }
    }
}

/// Spotlight-style picker. "Find Action" fuzzy-filters actions, dev tools and text transforms and runs the
/// highlighted one; "Recent Scratches" uses the same panel with its own ordering.
final class CommandPaletteController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let searchField = NSTextField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField.label("No matching actions", size: 13)
    private let countLabel = NSTextField.label("", size: 11)
    private var items: [PaletteItem] = []
    private var filtered: [PaletteItem] = []
    private let recentsKey = "paletteRecents"
    /// When false the items keep the order they were given in, and runs are not remembered.
    private let usesRecents: Bool
    private let noun: (one: String, many: String)
    private let verb: String
    private var initialRow = 0
    private var cycleKey: KeyCombo?
    private var keyMonitor: Any?

    convenience init() {
        self.init(title: "Find Action", placeholder: "Search actions and dev tools — base64, sort, sha256, camelCase…",
                  empty: "No matching actions", noun: ("action", "actions"), verb: "Run", usesRecents: true)
    }

    var placeholder: String {
        get { searchField.placeholderString ?? "" }
        set { searchField.placeholderString = newValue }
    }

    init(title: String, placeholder: String, empty: String, noun: (String, String), verb: String, usesRecents: Bool) {
        self.usesRecents = usesRecents
        self.noun = noun
        self.verb = verb
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 240)
        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)
        searchField.placeholderString = placeholder
        emptyLabel.stringValue = empty
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(in panel: NSPanel) {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active

        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        magnifier.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 18)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.lineBreakMode = .byTruncatingTail
        let searchRow = NSStackView(views: [magnifier, searchField])
        searchRow.spacing = 10
        searchRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        searchRow.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView()
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(countLabel)
        footer.addArrangedSubview(spacer)
        for (keys, hint) in [("↑ ↓", "Navigate"), ("↩", verb), ("esc", "Close")] {
            let caps = KeycapsView()
            caps.show(keys)
            footer.addArrangedSubview(caps)
            let label = NSTextField.label(hint, size: 11)
            footer.addArrangedSubview(label)
            footer.setCustomSpacing(14, after: label)
        }

        let topDivider = NSBox(), bottomDivider = NSBox()
        topDivider.boxType = .separator
        bottomDivider.boxType = .separator
        let stack = NSStackView(views: [searchRow, topDivider, scroll, bottomDivider, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in stack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        background.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        panel.contentView = background
        panel.initialFirstResponder = searchField
    }

    /// `initialRow` is highlighted while the query is empty; pressing `cycleKey` again moves down (⇧ moves up).
    func show(over parent: NSWindow?, items: [PaletteItem], initialRow: Int = 0, cycleKey: KeyCombo? = nil) {
        self.items = items
        self.initialRow = initialRow
        self.cycleKey = cycleKey
        installKeyMonitor()
        guard let window else { return }
        if let parent {
            let f = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.12))
        }
        searchField.stringValue = ""
        refilter()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) { refilter() }

    private func refilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty && !usesRecents {
            filtered = items
        } else if query.isEmpty {
            let recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
            let recentItems = recents.compactMap { id in items.first { $0.id == id } }
            filtered = recentItems + items.filter { !recents.contains($0.id) }
        } else {
            filtered = items
                .map { ($0, Self.score($0, query)) }
                .filter { $0.1 > 0 }
                .enumerated()
                .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .map(\.element.0)
        }
        table.reloadData()
        emptyLabel.isHidden = !filtered.isEmpty
        countLabel.stringValue = filtered.count == 1 ? "1 \(noun.one)" : "\(filtered.count) \(noun.many)"
        let row = query.isEmpty ? min(initialRow, max(filtered.count - 1, 0)) : 0
        if !filtered.isEmpty { table.selectRowIndexes([row], byExtendingSelection: false) }
        table.scrollRowToVisible(row)
    }

    /// Prefix and word-start matches beat substring matches, which beat loose subsequence matches.
    private static func score(_ item: PaletteItem, _ query: String) -> Int {
        let title = item.title.lowercased()
        let haystack = "\(title) \(item.category.lowercased()) \(item.keywords.lowercased())"
        if title.hasPrefix(query) { return 1000 - title.count }
        let words = haystack.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(query) }) { return 800 - title.count }
        let tokens = query.split(separator: " ")
        if tokens.count > 1, tokens.allSatisfy({ t in words.contains { $0.hasPrefix(t) } }) { return 700 - title.count }
        if haystack.contains(query) { return 600 - title.count }
        // Subsequence: every query character appears in order.
        var idx = haystack.startIndex
        var gaps = 0
        for ch in query where ch != " " {
            guard let found = haystack[idx...].firstIndex(of: ch) else { return 0 }
            gaps += haystack.distance(from: idx, to: found)
            idx = haystack.index(after: found)
        }
        return max(1, 300 - gaps)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HoverRowView()
        rowView.inset = 8
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("paletteCell"), owner: nil) as? PaletteCell ?? PaletteCell()
        cell.identifier = .init("paletteCell")
        cell.configure(filtered[row])
        return cell
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        run(row: table.clickedRow)
    }

    private func run(row: Int) {
        guard row >= 0, row < filtered.count else { return }
        let item = filtered[row]
        if usesRecents {
            var recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
            recents.removeAll { $0 == item.id }
            recents.insert(item.id, at: 0)
            UserDefaults.standard.set(Array(recents.prefix(8)), forKey: recentsKey)
        }
        window?.orderOut(nil)
        item.run()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(8); return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-8); return true
        case #selector(NSResponder.insertNewline(_:)): run(row: table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): window?.orderOut(nil); return true
        default: return false
        }
    }

    private func move(_ delta: Int, wrapping: Bool = false) {
        guard !filtered.isEmpty else { return }
        let target = table.selectedRow + delta
        let row = wrapping ? (target % filtered.count + filtered.count) % filtered.count
            : min(max(target, 0), filtered.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.orderOut(nil)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow, let cycle = self.cycleKey,
                  let combo = KeyCombo(event: event) else { return event }
            let backwards = combo.shift && !cycle.shift
            guard combo.cmd == cycle.cmd, combo.ctrl == cycle.ctrl, combo.alt == cycle.alt,
                  backwards || combo.shift == cycle.shift,
                  combo.key.lowercased() == cycle.key.lowercased() else { return event }
            self.move(backwards ? -1 : 1, wrapping: true)
            return nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.orderOut(nil)
    }
}

private final class PaletteCell: NSTableCellView {
    private let tile = SymbolTile(side: 22)
    private let title = NSTextField.label("", size: 13, color: .labelColor)
    private let category = NSTextField.label("", size: 11)
    private let keycaps = KeycapsView()

    init() {
        super.init(frame: .zero)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        category.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [tile, title, category, keycaps])
        row.spacing = 10
        row.setCustomSpacing(12, after: category)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        textField = title
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            tile.isOnSelection = selected
            keycaps.onSelection = selected
            title.textColor = selected ? .white : .labelColor
            category.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        }
    }

    func configure(_ item: PaletteItem) {
        title.stringValue = item.title
        category.stringValue = item.category
        let (symbol, tint) = item.tile
        tile.configure(symbol: symbol, tint: tint)
        keycaps.show(item.shortcut?.replacingOccurrences(of: " in list", with: ""))
    }
}
