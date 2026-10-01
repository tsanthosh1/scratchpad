import AppKit

struct ScratchMatch {
    let scratch: Scratch
    /// UTF-16 range in the whole file.
    let range: NSRange
    let line: Int
    let lineText: String
    /// UTF-16 range of the match inside `lineText`.
    let rangeInLine: NSRange
}

protocol FindInScratchesDelegate: AnyObject {
    func findInScratches(_ controller: FindInScratchesController, open match: ScratchMatch)
    /// Scratches to search, with the current editor contents already written to disk.
    func scratchesToSearch(_ controller: FindInScratchesController) -> [Scratch]
}

/// IntelliJ-style "Find in Files" limited to the scratch folder.
final class FindInScratchesController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: FindInScratchesDelegate?

    private let searchField = NSSearchField()
    private let caseButton = FindInScratchesController.toggle("Aa", tip: "Match Case")
    private let wordButton = FindInScratchesController.toggle("W", tip: "Whole Words")
    private let regexButton = FindInScratchesController.toggle(".*", tip: "Regex")
    private let typeFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let summary = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField.label("", size: 13, weight: .semibold, color: .labelColor)
    private let emptyHint = NSTextField.label("", size: 11)

    private var results: [ScratchMatch] = []
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "ScratchPad.findInScratches", qos: .userInitiated)
    private static let maxResults = 2000

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Find in Scratches"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 220)
        super.init(window: panel)
        panel.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func toggle(_ title: String, tip: String) -> HoverButton {
        let b = HoverButton(title: title, tip: tip, target: nil, action: nil,
                            font: .monospacedSystemFont(ofSize: 11, weight: .semibold))
        b.isToggle = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        return b
    }

    private func buildUI() {
        searchField.placeholderString = "Search all scratches"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.font = .systemFont(ofSize: 14)
        for b in [caseButton, wordButton, regexButton] {
            b.target = self
            b.action = #selector(optionsChanged)
        }
        typeFilter.target = self
        typeFilter.action = #selector(optionsChanged)
        typeFilter.controlSize = .small
        typeFilter.toolTip = "Limit to a file type"
        searchField.controlSize = .large
        let top = NSStackView(views: [searchField, typeFilter, caseButton, wordButton, regexButton])
        top.spacing = 6
        top.setCustomSpacing(10, after: typeFilter)

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: .init("match"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)!)
        emptyIcon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyState.orientation = .vertical
        emptyState.spacing = 6
        emptyState.alignment = .centerX
        for v in [emptyIcon, emptyTitle, emptyHint] { emptyState.addArrangedSubview(v) }
        emptyState.setCustomSpacing(10, after: emptyIcon)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.alignment = .center

        let stack = NSStackView(views: [top, summary, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 14, bottom: 10, right: 14)
        for v in [top, summary, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let background = NSVisualEffectView()
        background.material = .windowBackground
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        background.addSubview(emptyState)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        window?.contentView = background
        window?.initialFirstResponder = searchField
        updateEmptyState()
    }

    private func updateEmptyState() {
        let query = searchField.stringValue
        emptyState.isHidden = !results.isEmpty
        if query.isEmpty {
            emptyTitle.stringValue = "Search every scratch"
            emptyHint.stringValue = "Type to search. Use Aa for case, W for whole words and .* for regular expressions."
        } else {
            emptyTitle.stringValue = summary.textColor == .systemRed ? "Invalid regular expression" : "No matches"
            emptyHint.stringValue = "Try a different term or file type."
        }
    }

    // MARK: Presentation

    func show(over parent: NSWindow?, query: String?) {
        guard let window else { return }
        if !window.isVisible, let parent {
            let f = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.12))
        }
        if let query, !query.isEmpty, !query.contains("\n") {
            searchField.stringValue = query
        }
        rebuildTypeFilter()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
        search(immediately: true)
    }

    /// "All Types" plus the languages that currently have scratches, keeping the previous choice.
    private func rebuildTypeFilter() {
        let previous = typeFilter.selectedItem?.representedObject as? String
        let present = Set((delegate?.scratchesToSearch(self) ?? []).map(\.language))
        typeFilter.removeAllItems()
        typeFilter.addItem(withTitle: "All Types")
        for lang in Language.allCases where present.contains(lang) || lang.rawValue == previous {
            typeFilter.addItem(withTitle: lang.displayName)
            typeFilter.lastItem?.representedObject = lang.rawValue
            typeFilter.lastItem?.image = NSImage(systemSymbolName: lang.symbolName, accessibilityDescription: nil)
        }
        if let previous, let item = typeFilter.itemArray.first(where: { $0.representedObject as? String == previous }) {
            typeFilter.select(item)
        }
    }

    // MARK: Searching

    @objc private func optionsChanged() {
        search(immediately: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        search(immediately: false)
    }

    private func search(immediately: Bool) {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startSearch() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.12), execute: item)
    }

    private func startSearch() {
        generation += 1
        let gen = generation
        let query = searchField.stringValue
        guard !query.isEmpty else {
            apply([], summary: "", isError: false, gen: gen)
            return
        }

        var pattern = regexButton.state == .on ? query : NSRegularExpression.escapedPattern(for: query)
        if wordButton.state == .on { pattern = "\\b(?:\(pattern))\\b" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseButton.state != .on { options.insert(.caseInsensitive) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            apply([], summary: "Invalid regular expression", isError: true, gen: gen)
            return
        }

        let type = (typeFilter.selectedItem?.representedObject as? String).flatMap(Language.init(rawValue:))
        let scratches = (delegate?.scratchesToSearch(self) ?? []).filter { type == nil || $0.language == type }
        queue.async { [weak self] in
            var found: [ScratchMatch] = []
            var files = 0
            var truncated = false
            for scratch in scratches {
                guard self?.generation == gen else { return }
                guard let text = try? String(contentsOf: scratch.url, encoding: .utf8) else { continue }
                let ns = text as NSString
                let before = found.count
                var lineNumber = 1
                var lineCountedUpTo = 0
                regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                    guard let m, m.range.length > 0 else { return }
                    if found.count >= Self.maxResults {
                        truncated = true
                        stop.pointee = true
                        return
                    }
                    lineNumber += Self.newlines(in: ns, from: lineCountedUpTo, to: m.range.location)
                    lineCountedUpTo = m.range.location
                    let lineRange = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
                    var line = ns.substring(with: lineRange)
                    while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
                    var inLine = NSRange(location: m.range.location - lineRange.location, length: m.range.length)
                    inLine.length = min(inLine.length, max((line as NSString).length - inLine.location, 0))
                    let (display, displayRange) = Self.clip(line, around: inLine)
                    found.append(ScratchMatch(scratch: scratch, range: m.range, line: lineNumber,
                                              lineText: display, rangeInLine: displayRange))
                }
                if found.count > before { files += 1 }
                if truncated { break }
            }
            let noun = found.count == 1 ? "match" : "matches"
            var text = found.isEmpty ? "No matches" : "\(found.count)\(truncated ? "+" : "") \(noun) in \(files) scratch\(files == 1 ? "" : "es")"
            if truncated { text += " (showing the first \(Self.maxResults))" }
            DispatchQueue.main.async { self?.apply(found, summary: text, isError: false, gen: gen) }
        }
    }

    private static func newlines(in s: NSString, from: Int, to: Int) -> Int {
        guard to > from else { return 0 }
        var count = 0
        for i in from..<to where s.character(at: i) == 10 { count += 1 }
        return count
    }

    /// Keeps long lines readable by trimming leading indentation and cutting around the match.
    private static func clip(_ line: String, around range: NSRange) -> (String, NSRange) {
        let ns = line as NSString
        var start = 0
        while start < range.location, let c = UnicodeScalar(ns.character(at: start)), CharacterSet.whitespaces.contains(c) {
            start += 1
        }
        var prefix = ""
        if range.location - start > 60 {
            start = range.location - 40
            prefix = "…"
        }
        let end = min(ns.length, max(range.location + range.length + 120, start + 160))
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let suffix = end < ns.length ? "…" : ""
        let shifted = NSRange(location: range.location - start + (prefix as NSString).length, length: range.length)
        return (prefix + body + suffix, shifted)
    }

    private func apply(_ matches: [ScratchMatch], summary text: String, isError: Bool, gen: Int) {
        guard gen == generation else { return }
        results = matches
        summary.stringValue = text
        summary.textColor = isError ? .systemRed : .secondaryLabelColor
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        updateEmptyState()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HoverRowView()
        rowView.inset = 0
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("matchCell"), owner: nil) as? MatchCell ?? MatchCell()
        cell.identifier = .init("matchCell")
        cell.configure(results[row])
        return cell
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < results.count else { return }
        let match = results[row]
        window?.orderOut(nil)
        delegate?.findInScratches(self, open: match)
    }

    // Arrow keys and Return work while typing in the search field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): moveSelection(10); return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): moveSelection(-10); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): window?.orderOut(nil); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelected() } else { super.keyDown(with: event) }
    }
}

private final class MatchCell: NSTableCellView {
    private let tile = SymbolTile(side: 18)
    private let lineLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private var match: ScratchMatch?

    init() {
        super.init(frame: .zero)
        lineLabel.lineBreakMode = .byTruncatingTail
        lineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lineLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.alignment = .right
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [tile, lineLabel, locationLabel])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            locationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            tile.isOnSelection = backgroundStyle == .emphasized
            if let match { render(match, selected: backgroundStyle == .emphasized) }
        }
    }

    func configure(_ match: ScratchMatch) {
        self.match = match
        tile.configure(match.scratch.language)
        render(match, selected: backgroundStyle == .emphasized)
    }

    private func render(_ match: ScratchMatch, selected: Bool) {
        let font = NSFont(name: Settings.shared.fontFamily, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: match.lineText, attributes: [
            .font: font, .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
        ])
        let bold = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: 12) ?? font
        if NSMaxRange(match.rangeInLine) <= text.length {
            text.addAttributes([
                .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.55),
                .foregroundColor: NSColor.black,
                .font: bold,
            ], range: match.rangeInLine)
        }
        lineLabel.attributedStringValue = text
        locationLabel.stringValue = "\(match.scratch.name):\(match.line)"
        locationLabel.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }
}
