import AppKit

struct PaletteItem {
    let id: String
    let title: String
    let category: String
    var shortcut: String?
    var keywords: String = ""
    var icon: (symbol: String, tint: NSColor)?
    /// Nesting level, shown as indentation while the query is empty (an outline).
    var indent = 0
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
        case "Format": return ("bold.italic.underline", .systemPink)
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
    /// Title character offsets to highlight, by item id (set by `matcher`).
    private var highlights: [String: [Int]] = [:]
    /// Replaces the built-in scoring. Gets the trimmed query as typed; returns nil to hide the item, or a
    /// score (higher first) and the title character offsets that matched.
    var matcher: ((PaletteItem, String) -> (score: Int, positions: [Int])?)?
    /// The highlighted row changed (for previews).
    var onHighlight: ((PaletteItem) -> Void)?
    /// The panel closed: true when an item was run, false when dismissed.
    var onDismiss: ((_ accepted: Bool) -> Void)?
    private var isOpen = false

    /// What's typed in the search field.
    var query: String { searchField.stringValue }
    private let recentsKey = "paletteRecents"
    /// When false the items keep the order they were given in, and runs are not remembered.
    private let usesRecents: Bool
    private let noun: (one: String, many: String)
    private let verb: String
    private var initialRow = 0
    private var cycleKey: KeyCombo?
    private var keyMonitor: Any?
    private weak var parentWindow: NSWindow?
    /// Height to open at (capped to the parent window); nil keeps whatever size the panel has.
    private let preferredHeight: CGFloat?

    convenience init() {
        self.init(title: "Find Action", placeholder: "Search actions and dev tools — base64, sort, sha256, camelCase…",
                  empty: "No matching actions", noun: ("action", "actions"), verb: "Run", usesRecents: true)
    }

    var placeholder: String {
        get { searchField.placeholderString ?? "" }
        set { searchField.placeholderString = newValue }
    }

    init(title: String, placeholder: String, empty: String, noun: (String, String), verb: String, usesRecents: Bool,
         height: CGFloat? = nil) {
        self.usesRecents = usesRecents
        self.preferredHeight = height
        self.noun = noun
        self.verb = verb
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
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
        self.parentWindow = parent
        self.items = items
        self.initialRow = initialRow
        self.cycleKey = cycleKey
        isOpen = true
        installKeyMonitor()
        guard let window else { return }
        if let parent {
            let f = parent.frame
            if let preferredHeight {
                let height = max(window.minSize.height, min(preferredHeight, f.height * 0.8))
                window.setContentSize(NSSize(width: window.frame.width, height: height))
            }
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
        let typed = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let query = typed.lowercased()
        highlights = [:]
        if let matcher, !query.isEmpty {
            var scored: [(item: PaletteItem, score: Int)] = []
            for item in items {
                guard let match = matcher(item, typed) else { continue }
                scored.append((item, match.score))
                highlights[item.id] = match.positions
            }
            filtered = scored.enumerated()
                .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
                .map(\.element.item)
        } else if query.isEmpty && !usesRecents {
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
        if words.contains(where: { $0.hasPrefix(query) }) {
            var s = 800 - title.count
            if (item.id.contains("plaintext") || item.id == "language.text" || item.title.localizedCaseInsensitiveContains("Plain Text")),
               "text".hasPrefix(query) || "plain".hasPrefix(query) {
                s += 120
            }
            return s
        }
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
        cell.configure(filtered[row], highlights: highlights[filtered[row].id] ?? [],
                       indent: searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? filtered[row].indent : 0)
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
        let parent = parentWindow
        finish(accepted: true)
        window?.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        item.run()
    }

    private func finish(accepted: Bool) {
        guard isOpen else { return }
        isOpen = false
        onDismiss?(accepted)
    }

    private func dismiss() {
        finish(accepted: false)
        window?.orderOut(nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard isOpen, row >= 0, row < filtered.count else { return }
        onHighlight?(filtered[row])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(8); return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-8); return true
        case #selector(NSResponder.insertNewline(_:)): run(row: table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
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
        dismiss()
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
        dismiss()
    }
}

private final class PaletteCell: NSTableCellView {
    private let tile = SymbolTile(side: 22)
    private let title = NSTextField.label("", size: 13, color: .labelColor)
    private let category = NSTextField.label("", size: 11)
    private let keycaps = KeycapsView()
    private var leading: NSLayoutConstraint!

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
        leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            leading,
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
            applyHighlights()
        }
    }

    private var highlights: [Int] = []

    /// Matched characters are bold and tinted, like IntelliJ's Go to File.
    private func applyHighlights() {
        guard !highlights.isEmpty else { return }
        let selected = backgroundStyle == .emphasized
        let text = NSMutableAttributedString(string: title.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: selected ? NSColor.white : .labelColor,
        ])
        let characters = Array(title.stringValue)
        var utf16Offset = 0
        var starts: [Int] = []
        for character in characters {
            starts.append(utf16Offset)
            utf16Offset += String(character).utf16.count
        }
        for index in highlights where index < characters.count {
            let range = NSRange(location: starts[index], length: String(characters[index]).utf16.count)
            text.addAttributes([.font: NSFont.boldSystemFont(ofSize: 13),
                                .foregroundColor: selected ? NSColor.white : NSColor.controlAccentColor], range: range)
            if selected { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        title.attributedStringValue = text
    }

    func configure(_ item: PaletteItem, highlights: [Int] = [], indent: Int = 0) {
        leading.constant = 16 + CGFloat(min(indent, 10)) * 18
        title.stringValue = item.title
        self.highlights = highlights
        applyHighlights()
        category.stringValue = item.category
        let (symbol, tint) = item.tile
        tile.configure(symbol: symbol, tint: tint)
        keycaps.show(item.shortcut?.replacingOccurrences(of: " in list", with: ""))
    }
}

/// A transient panel over the main window (pickers, Find in Files). Menu key equivalents are matched before a text
/// field sees the key, so editing keys that are also app shortcuts (⌘⌫ is Delete Line) go to the focused text instead.
final class PopupPanel: NSPanel {
    private static let editingKeyCodes: Set<UInt16> = [51, 117, 123, 124, 125, 126, 115, 119]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, !flags.isDisjoint(with: [.command, .option]),
           Self.editingKeyCodes.contains(event.keyCode), let text = firstResponder as? NSTextView, text.isEditable {
            text.keyDown(with: event)
            return true
        }
        // Main window actions are disabled while a popup is key, so ⌘W closes the popup rather than a tab.
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
