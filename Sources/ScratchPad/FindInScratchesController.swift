import AppKit

struct ScratchMatch {
    let scratch: Scratch
    /// UTF-16 range in the whole file.
    let range: NSRange
    let line: Int
    let lineText: String
    /// UTF-16 range of the match inside `lineText`.
    let rangeInLine: NSRange
    /// UTF-16 range of the match inside the full (unclipped) line.
    let column: NSRange
}

protocol FindInScratchesDelegate: AnyObject {
    func findInScratches(_ controller: FindInScratchesController, open match: ScratchMatch)
    /// Files to search (scratches, external folders, opened files), with the editor's contents already on disk.
    func scratchesToSearch(_ controller: FindInScratchesController) -> [Scratch]
}

/// IntelliJ-style "Find in Files" over scratches, external folders and opened files: filters for location,
/// file type and file name mask, results grouped by file, and a preview of the lines around the selected match.
final class FindInScratchesController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSplitViewDelegate {
    weak var delegate: FindInScratchesDelegate?

    private struct FileGroup {
        let scratch: Scratch
        var matches: [ScratchMatch]
    }

    private enum Row {
        case file(Int)
        case match(Int, Int)
    }

    private let searchField = NSSearchField()
    private let caseButton = FindInScratchesController.toggle("Aa", tip: "Match Case")
    private let wordButton = FindInScratchesController.toggle("W", tip: "Whole Words")
    private let regexButton = FindInScratchesController.toggle(".*", tip: "Regular Expression")
    private let locationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maskField = NSSearchField()
    private lazy var resetButton = HoverButton(title: "Reset Filters", tip: "Search everything again",
                                               target: self, action: #selector(resetFilters), font: .systemFont(ofSize: 11))
    private let spinner = NSProgressIndicator()
    private let summary = NSTextField.label("", size: 11)
    private let hints = NSTextField.label("↩ Open   ↑↓ Move   ⎋ Close", size: 11, color: .tertiaryLabelColor)
    private let table = NSTableView()
    private let split = NSSplitView()
    private let previewTitle = NSTextField.label("", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let previewText = NSTextView()
    private let previewScroll = NSScrollView()
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField.label("", size: 15, weight: .semibold, color: .labelColor)
    private let emptyHint = NSTextField.label("", size: 12)

    private var groups: [FileGroup] = []
    private var rows: [Row] = []
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "ScratchPad.findInFiles", qos: .userInitiated)
    private var previewCache: (path: String, lines: [String])?
    private static let maxResults = 5000
    private static let maxFileSize = 5_000_000
    private static let openedKey = "\u{1}opened"
    private let defaults = UserDefaults.standard

    init() {
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Find in Files"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 360)
        panel.setFrameAutosaveName("ScratchPad.FindInFiles")
        super.init(window: panel)
        panel.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func toggle(_ title: String, tip: String) -> HoverButton {
        let b = HoverButton(title: title, tip: tip, target: nil, action: nil,
                            font: .monospacedSystemFont(ofSize: 12, weight: .semibold))
        b.isToggle = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return b
    }

    private static func caption(_ text: String) -> NSTextField {
        NSTextField.label(text, size: 11, weight: .medium, color: .secondaryLabelColor)
    }

    // MARK: Layout

    private func buildUI() {
        searchField.placeholderString = "Search text in every scratch and external folder"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.font = .systemFont(ofSize: 15)
        searchField.controlSize = .large
        searchField.setContentHuggingPriority(.init(1), for: .horizontal)
        for (button, key) in [(caseButton, "find.case"), (wordButton, "find.word"), (regexButton, "find.regex")] {
            button.target = self
            button.action = #selector(optionsChanged)
            button.state = defaults.bool(forKey: key) ? .on : .off
        }
        let queryRow = NSStackView(views: [searchField, caseButton, wordButton, regexButton])
        queryRow.spacing = 4
        queryRow.setCustomSpacing(10, after: searchField)

        for popup in [locationPopup, typePopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12)
            popup.target = self
            popup.action = #selector(optionsChanged)
        }
        locationPopup.toolTip = "Where to search"
        typePopup.toolTip = "Limit to a file type"
        locationPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        maskField.controlSize = .small
        maskField.font = .systemFont(ofSize: 12)
        maskField.placeholderString = "*.json, !*test*"
        maskField.toolTip = "File name mask: comma-separated wildcards; prefix with ! to exclude"
        maskField.delegate = self
        maskField.sendsSearchStringImmediately = true
        maskField.stringValue = defaults.string(forKey: "find.mask") ?? ""
        maskField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        resetButton.contentTintColor = .controlAccentColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let filterSpacer = NSView()
        filterSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let filterRow = NSStackView(views: [
            Self.caption("In"), locationPopup, Self.caption("Type"), typePopup, Self.caption("File mask"), maskField,
            resetButton, filterSpacer, spinner,
        ])
        filterRow.spacing = 6
        for caption in filterRow.arrangedSubviews.compactMap({ $0 as? NSTextField }) { filterRow.setCustomSpacing(4, after: caption) }
        filterRow.setCustomSpacing(16, after: locationPopup)
        filterRow.setCustomSpacing(16, after: typePopup)
        filterRow.setCustomSpacing(12, after: maskField)

        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.menu = NSMenu()
        table.menu?.delegate = self
        let resultsScroll = NSScrollView()
        resultsScroll.documentView = table
        resultsScroll.hasVerticalScroller = true
        resultsScroll.drawsBackground = false

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.textContainerInset = NSSize(width: 8, height: 6)
        previewText.isHorizontallyResizable = true
        previewText.textContainer?.widthTracksTextView = false
        previewText.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previewText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previewScroll.documentView = previewText
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = .textBackgroundColor
        previewTitle.lineBreakMode = .byTruncatingMiddle
        let previewBar = NSStackView(views: [previewTitle])
        previewBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        previewBar.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let previewBox = NSStackView(views: [previewBar, previewScroll])
        previewBox.orientation = .vertical
        previewBox.spacing = 0
        for v in [previewBar, previewScroll] { v.widthAnchor.constraint(equalTo: previewBox.widthAnchor).isActive = true }

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(resultsScroll)
        split.addArrangedSubview(previewBox)
        split.autosaveName = "ScratchPad.FindInFiles.split"
        split.setHoldingPriority(.init(240), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [summary, footerSpacer, hints])
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        footer.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let header = NSStackView(views: [queryRow, filterRow])
        header.orientation = .vertical
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 34, left: 14, bottom: 10, right: 14)
        for v in [queryRow, filterRow] {
            v.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -28).isActive = true
        }
        let topDivider = NSBox(), bottomDivider = NSBox()
        topDivider.boxType = .separator
        bottomDivider.boxType = .separator

        let stack = NSStackView(views: [header, topDivider, split, bottomDivider, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in stack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        split.setContentHuggingPriority(.init(1), for: .vertical)

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)!)
        emptyIcon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyState.orientation = .vertical
        emptyState.spacing = 6
        emptyState.alignment = .centerX
        for v in [emptyIcon, emptyTitle, emptyHint] { emptyState.addArrangedSubview(v) }
        emptyState.setCustomSpacing(12, after: emptyIcon)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.alignment = .center
        emptyHint.maximumNumberOfLines = 0

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
            emptyState.centerXAnchor.constraint(equalTo: split.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: split.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: split.widthAnchor, constant: -60),
        ])
        window?.contentView = background
        window?.initialFirstResponder = searchField
        updateEmptyState()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 100)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 80)
    }

    private func updateEmptyState() {
        let hasResults = !rows.isEmpty
        emptyState.isHidden = hasResults
        split.arrangedSubviews.last?.isHidden = !hasResults
        if searchField.stringValue.isEmpty {
            let external = ExternalFolders.all.count
            emptyTitle.stringValue = "Find in Files"
            var hint = "Searches every scratch"
            if external > 0 { hint += " and \(external == 1 ? "1 external folder" : "\(external) external folders")" }
            hint += ".\nNarrow it down with In, Type and File mask. Aa matches case, W whole words, .* regular expressions."
            emptyHint.stringValue = hint
        } else if summary.textColor == .systemRed {
            emptyTitle.stringValue = "Invalid regular expression"
            emptyHint.stringValue = summary.stringValue
        } else {
            emptyTitle.stringValue = "No matches"
            emptyHint.stringValue = isFiltered ? "Nothing matches with the current filters. Try Reset Filters." : "Try a different search term."
        }
    }

    // MARK: Presentation

    /// Shows the panel; `location` (a folder path) narrows the search to that folder.
    func show(over parent: NSWindow?, query: String?, location: String? = nil) {
        guard let window else { return }
        if !window.isVisible, let parent, !window.setFrameUsingName("ScratchPad.FindInFiles") {
            let f = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.08))
        }
        if let query, !query.isEmpty, !query.contains("\n") {
            searchField.stringValue = query
        }
        rebuildFilters(selecting: location)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
        search(immediately: true)
    }

    private var candidates: [Scratch] { delegate?.scratchesToSearch(self) ?? [] }

    private var isFiltered: Bool {
        locationPopup.indexOfSelectedItem > 0 || typePopup.indexOfSelectedItem > 0
            || !maskField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func rebuildFilters(selecting location: String? = nil) {
        let all = candidates
        rebuildLocations(all, selecting: location)
        rebuildTypes(all)
        resetButton.isHidden = !isFiltered
    }

    private func addLocation(_ title: String, key: String, symbol: String, tint: NSColor, indent: Int = 0, tip: String? = nil) {
        locationPopup.addItem(withTitle: title)
        guard let item = locationPopup.lastItem else { return }
        item.representedObject = key
        item.indentationLevel = indent
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [tint]))
    }

    /// Everything, the scratches folder and its folders, each external folder with its top-level folders, and
    /// opened files.
    private func rebuildLocations(_ all: [Scratch], selecting location: String?) {
        let previous = location ?? (locationPopup.selectedItem?.representedObject as? String)
        locationPopup.removeAllItems()
        addLocation("Everywhere", key: "", symbol: "globe", tint: .systemGray)
        let scratches = AppPaths.scratches.standardizedFileURL.path
        addLocation("Scratches", key: scratches, symbol: "tray.full.fill", tint: .systemBlue)
        let folders = ScratchStore.folders()
        for folder in folders where !folder.isExternal {
            addLocation(folder.name, key: folder.url.standardizedFileURL.path, symbol: "folder.fill", tint: .systemBlue,
                        indent: 1 + folder.id.filter { $0 == "/" }.count, tip: folder.id)
        }
        let roots = ExternalFolders.all.filter { FileManager.default.fileExists(atPath: $0) }
        if !roots.isEmpty { locationPopup.menu?.addItem(.separator()) }
        for root in roots {
            addLocation((root as NSString).lastPathComponent, key: root, symbol: "externaldrive.fill", tint: .systemOrange,
                        tip: ExternalFolders.displayPath(root))
            for folder in folders where folder.isExternal && !folder.isExternalRoot && folder.parent == root {
                addLocation(folder.name, key: folder.id, symbol: "folder.fill", tint: .systemOrange, indent: 1,
                            tip: ExternalFolders.displayPath(folder.id))
            }
        }
        if all.contains(where: { !$0.isListed }) {
            locationPopup.menu?.addItem(.separator())
            addLocation("Opened Files", key: Self.openedKey, symbol: "doc.fill", tint: .systemGray)
        }
        if let previous, !previous.isEmpty {
            if let item = locationPopup.itemArray.first(where: { $0.representedObject as? String == previous }) {
                locationPopup.select(item)
            } else if previous.hasPrefix("/") {
                // A deeper folder (from a folder's "Find in This Folder…").
                locationPopup.menu?.addItem(.separator())
                addLocation((previous as NSString).lastPathComponent, key: previous, symbol: "folder.fill",
                            tint: ExternalFolders.root(containing: previous) != nil ? .systemOrange : .systemBlue,
                            tip: ExternalFolders.displayPath(previous))
                locationPopup.selectItem(at: locationPopup.numberOfItems - 1)
            }
        }
    }

    /// "All Types" plus the file types present, with how many files of each there are.
    private func rebuildTypes(_ all: [Scratch]) {
        let previous = typePopup.selectedItem?.representedObject as? String
        let counts = Dictionary(grouping: all, by: \.language).mapValues(\.count)
        typePopup.removeAllItems()
        typePopup.addItem(withTitle: "All Types")
        for lang in Language.allCases where counts[lang] != nil || lang.rawValue == previous {
            typePopup.addItem(withTitle: "\(lang.displayName)  \(counts[lang] ?? 0)")
            typePopup.lastItem?.representedObject = lang.rawValue
            typePopup.lastItem?.image = NSImage(systemSymbolName: lang.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [lang.tint]))
        }
        if let previous, let item = typePopup.itemArray.first(where: { $0.representedObject as? String == previous }) {
            typePopup.select(item)
        }
    }

    @objc private func resetFilters() {
        locationPopup.selectItem(at: 0)
        typePopup.selectItem(at: 0)
        maskField.stringValue = ""
        defaults.removeObject(forKey: "find.mask")
        optionsChanged()
    }

    // MARK: Filtering

    private func scope(_ all: [Scratch]) -> [Scratch] {
        let location = locationPopup.selectedItem?.representedObject as? String ?? ""
        let type = (typePopup.selectedItem?.representedObject as? String).flatMap(Language.init(rawValue:))
        let mask = Self.parseMask(maskField.stringValue)
        return all.filter { scratch in
            if location == Self.openedKey { if scratch.isListed { return false } }
            else if !location.isEmpty, !scratch.url.path.hasPrefix(location + "/") { return false }
            if let type, scratch.language != type { return false }
            return Self.matches(mask, scratch.url)
        }
    }

    private static func parseMask(_ text: String) -> (include: [String], exclude: [String]) {
        let parts = text.split { $0 == "," || $0 == ";" || $0 == " " }.map(String.init).filter { !$0.isEmpty }
        return (parts.filter { !$0.hasPrefix("!") }, parts.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) })
    }

    private static func matches(_ mask: (include: [String], exclude: [String]), _ url: URL) -> Bool {
        func hit(_ pattern: String) -> Bool {
            let subject = pattern.contains("/") ? url.path : url.lastPathComponent
            let glob = pattern.contains("/") && !pattern.hasPrefix("/") && !pattern.hasPrefix("*") ? "*/" + pattern : pattern
            // A bare word ("api") means "contains".
            let wildcard = glob.contains { "*?[".contains($0) } ? glob : "*\(glob)*"
            return fnmatch(wildcard, subject, FNM_CASEFOLD) == 0
        }
        if mask.exclude.contains(where: hit) { return false }
        return mask.include.isEmpty || mask.include.contains(where: hit)
    }

    // MARK: Searching

    @objc private func optionsChanged() {
        defaults.set(caseButton.state == .on, forKey: "find.case")
        defaults.set(wordButton.state == .on, forKey: "find.word")
        defaults.set(regexButton.state == .on, forKey: "find.regex")
        defaults.set(maskField.stringValue, forKey: "find.mask")
        resetButton.isHidden = !isFiltered
        search(immediately: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === maskField {
            defaults.set(maskField.stringValue, forKey: "find.mask")
            resetButton.isHidden = !isFiltered
        }
        search(immediately: false)
    }

    private func search(immediately: Bool) {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startSearch() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.15), execute: item)
    }

    /// Plain text of a searchable file, or nil for binary, oversized or unreadable files.
    private static func readText(_ scratch: Scratch) -> String? {
        if scratch.language.isRichText { return RichTextIO.load(scratch.url)?.string }
        guard let size = try? scratch.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: scratch.url), !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func startSearch() {
        generation += 1
        let gen = generation
        let query = searchField.stringValue
        previewCache = nil
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
            apply([], summary: "Invalid regular expression: check brackets and escapes", isError: true, gen: gen)
            return
        }

        let files = scope(candidates)
        let place = locationPopup.indexOfSelectedItem > 0 ? " in \(locationPopup.titleOfSelectedItem ?? "")" : ""
        spinner.startAnimation(nil)
        queue.async { [weak self] in
            var found: [FileGroup] = []
            var total = 0
            var searched = 0
            var truncated = false
            for scratch in files {
                guard self?.generation == gen else { return }
                guard let text = Self.readText(scratch) else { continue }
                searched += 1
                let matches = Self.matches(of: regex, in: text, scratch: scratch, limit: Self.maxResults - total)
                if matches.isEmpty { continue }
                found.append(FileGroup(scratch: scratch, matches: matches))
                total += matches.count
                if total >= Self.maxResults { truncated = true; break }
            }
            let fileNoun = found.count == 1 ? "file" : "files"
            var text = total == 0 ? "No matches" : "\(total)\(truncated ? "+" : "") \(total == 1 ? "match" : "matches") in \(found.count) \(fileNoun)"
            text += " · searched \(searched) \(searched == 1 ? "file" : "files")\(place)"
            if truncated { text += " · showing the first \(Self.maxResults)" }
            DispatchQueue.main.async { self?.apply(found, summary: text, isError: false, gen: gen) }
        }
    }

    private static func matches(of regex: NSRegularExpression, in text: String, scratch: Scratch, limit: Int) -> [ScratchMatch] {
        let ns = text as NSString
        var found: [ScratchMatch] = []
        var lineNumber = 1
        var countedUpTo = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m, m.range.length > 0 else { return }
            if found.count >= limit {
                stop.pointee = true
                return
            }
            lineNumber += newlines(in: ns, from: countedUpTo, to: m.range.location)
            countedUpTo = m.range.location
            let lineRange = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
            var line = ns.substring(with: lineRange)
            while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
            var inLine = NSRange(location: m.range.location - lineRange.location, length: m.range.length)
            inLine.length = min(inLine.length, max((line as NSString).length - inLine.location, 0))
            let (display, displayRange) = clip(line, around: inLine)
            found.append(ScratchMatch(scratch: scratch, range: m.range, line: lineNumber, lineText: display,
                                      rangeInLine: displayRange, column: inLine))
        }
        return found
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
        let end = min(ns.length, max(range.location + range.length + 160, start + 200))
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let suffix = end < ns.length ? "…" : ""
        let shifted = NSRange(location: range.location - start + (prefix as NSString).length, length: range.length)
        return (prefix + body + suffix, shifted)
    }

    private func apply(_ found: [FileGroup], summary text: String, isError: Bool, gen: Int) {
        guard gen == generation else { return }
        spinner.stopAnimation(nil)
        groups = found
        rows = found.enumerated().flatMap { index, group in
            [Row.file(index)] + group.matches.indices.map { Row.match(index, $0) }
        }
        summary.stringValue = text
        summary.textColor = isError ? .systemRed : .secondaryLabelColor
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .match = $0 { return true } else { return false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updatePreview()
        updateEmptyState()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .file = rows[row] { return row == 0 ? 30 : 36 }
        return 22
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HoverRowView()
        rowView.inset = 6
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .file(let index):
            let cell = tableView.makeView(withIdentifier: .init("fileCell"), owner: nil) as? FileResultCell ?? FileResultCell()
            cell.identifier = .init("fileCell")
            cell.configure(groups[index].scratch, count: groups[index].matches.count)
            return cell
        case .match(let index, let match):
            let cell = tableView.makeView(withIdentifier: .init("matchCell"), owner: nil) as? MatchCell ?? MatchCell()
            cell.identifier = .init("matchCell")
            cell.configure(groups[index].matches[match])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func match(at row: Int) -> ScratchMatch? {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .file(let index): return groups[index].matches.first
        case .match(let index, let match): return groups[index].matches[match]
        }
    }

    @objc private func openSelected() {
        guard let match = match(at: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) else { return }
        window?.orderOut(nil)
        delegate?.findInScratches(self, open: match)
    }

    // MARK: Preview

    private func updatePreview() {
        guard let match = match(at: table.selectedRow), let group = groups.first(where: { $0.scratch == match.scratch }) else {
            previewText.string = ""
            previewTitle.stringValue = ""
            return
        }
        let path = match.scratch.url.path
        if previewCache?.path != path {
            let text = Self.readText(match.scratch) ?? ""
            previewCache = (path, text.components(separatedBy: "\n"))
        }
        let lines = previewCache?.lines ?? []
        previewTitle.stringValue = "\(Self.location(of: match.scratch))  ·  line \(match.line)"
        let first = max(1, match.line - 60), last = min(lines.count, match.line + 60)
        guard first <= last else { previewText.string = ""; return }

        let font = NSFont(name: Settings.shared.fontFamily, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let gutterWidth = String(last).count
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        var matchLineRange = NSRange(location: 0, length: 0)
        let byLine = Dictionary(grouping: group.matches.filter { $0.line >= first && $0.line <= last }, by: \.line)
        for number in first...last {
            var line = lines[number - 1]
            if line.hasSuffix("\r") { line.removeLast() }
            let gutter = String(repeating: " ", count: gutterWidth - String(number).count) + "\(number)  "
            let start = output.length
            output.append(NSAttributedString(string: gutter, attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
            ]))
            let textStart = output.length
            output.append(NSAttributedString(string: line + "\n", attributes: [
                .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
            ]))
            for hit in byLine[number] ?? [] where NSMaxRange(hit.column) <= (line as NSString).length {
                let range = NSRange(location: textStart + hit.column.location, length: hit.column.length)
                output.addAttributes([.backgroundColor: NSColor.findHighlightColor.withAlphaComponent(hit.range == match.range ? 0.9 : 0.4),
                                      .foregroundColor: NSColor.black], range: range)
            }
            if number == match.line {
                matchLineRange = NSRange(location: start, length: output.length - start)
                output.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.12),
                                    range: NSRange(location: start, length: textStart - start))
            }
        }
        previewText.textStorage?.setAttributedString(output)
        previewText.layoutManager?.ensureLayout(for: previewText.textContainer!)
        if let layout = previewText.layoutManager, let container = previewText.textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: matchLineRange, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let visible = previewScroll.contentView.bounds.height
            previewScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.midY - visible / 2)))
            previewScroll.reflectScrolledClipView(previewScroll.contentView)
        }
    }

    /// "Scratches/work", "project/src" (external) or "~/Downloads" (opened file).
    fileprivate static func location(of scratch: Scratch) -> String {
        if scratch.isInScratchFolder {
            return scratch.folder.isEmpty ? "Scratches" : "Scratches/\(scratch.folder)"
        }
        if let root = scratch.externalRoot {
            let name = (root as NSString).lastPathComponent
            return name + scratch.folder.dropFirst(root.count)
        }
        return ExternalFolders.displayPath(scratch.url.deletingLastPathComponent().path)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard let match = match(at: row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        menu.addItem(ClosureMenuItem(title: "Open") { [weak self] in self?.openSelected() })
        menu.addItem(ClosureMenuItem(title: "Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([match.scratch.url])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(match.scratch.url.path, forType: .string)
        })
        menu.addItem(ClosureMenuItem(title: "Copy Path with Line Number") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(match.scratch.url.path):\(match.line)", forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Search Only in \(Self.location(of: match.scratch))") { [weak self] in
            guard let self else { return }
            self.rebuildLocations(self.candidates, selecting: match.scratch.url.deletingLastPathComponent().path)
            self.optionsChanged()
        })
        menu.addItem(ClosureMenuItem(title: "Search Only \(match.scratch.language.displayName) Files") { [weak self] in
            guard let self else { return }
            if let item = self.typePopup.itemArray.first(where: { $0.representedObject as? String == match.scratch.language.rawValue }) {
                self.typePopup.select(item)
            }
            self.optionsChanged()
        })
    }

    // MARK: Keyboard

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

    /// Moves between matches, skipping the file header rows.
    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var row = table.selectedRow
        var remaining = abs(delta)
        let step = delta > 0 ? 1 : -1
        while remaining > 0 {
            var next = row + step
            while next >= 0, next < rows.count, case .file = rows[next] { next += step }
            guard next >= 0, next < rows.count else { break }
            row = next
            remaining -= 1
        }
        guard row >= 0 else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if step < 0, row > 0, case .file = rows[row - 1] { table.scrollRowToVisible(row - 1) }
    }

    override func cancelOperation(_ sender: Any?) {
        window?.orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelected() } else { super.keyDown(with: event) }
    }
}

/// File header in the results: icon, name, where it lives and how many matches it has.
private final class FileResultCell: NSTableCellView {
    private let tile = SymbolTile(side: 18)
    private let name = NSTextField.label("", size: 12, weight: .semibold, color: .labelColor)
    private let place = NSTextField.label("", size: 11)
    private let badge = NSTextField.label("", size: 10, weight: .semibold)
    private let external = NSTextField.label("EXTERNAL", size: 9, weight: .bold, color: .systemOrange)

    init() {
        super.init(frame: .zero)
        place.lineBreakMode = .byTruncatingMiddle
        place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        place.setContentHuggingPriority(.init(1), for: .horizontal)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        let row = NSStackView(views: [tile, name, external, place, badge])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ scratch: Scratch, count: Int) {
        tile.configure(scratch.language)
        name.stringValue = scratch.name
        place.stringValue = FindInScratchesController.location(of: scratch)
        external.isHidden = scratch.isInScratchFolder
        external.stringValue = scratch.isListed ? "EXTERNAL" : "OPENED"
        badge.stringValue = " \(count) "
        toolTip = scratch.url.path
        updateColors()
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        tile.isOnSelection = selected
        name.textColor = selected ? .white : .labelColor
        place.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        badge.textColor = selected ? .white : .secondaryLabelColor
        badge.layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).cgColor
    }
}

/// One matching line: line number and the line with the match highlighted.
private final class MatchCell: NSTableCellView {
    private let number = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")
    private var match: ScratchMatch?

    init() {
        super.init(frame: .zero)
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.alignment = .right
        number.widthAnchor.constraint(equalToConstant: 40).isActive = true
        lineLabel.lineBreakMode = .byTruncatingTail
        lineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lineLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [number, lineLabel])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let match { render(match, selected: backgroundStyle == .emphasized) } }
    }

    func configure(_ match: ScratchMatch) {
        self.match = match
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
                .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.6),
                .foregroundColor: NSColor.black,
                .font: bold,
            ], range: match.rangeInLine)
        }
        lineLabel.attributedStringValue = text
        number.stringValue = "\(match.line)"
        number.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
    }
}
