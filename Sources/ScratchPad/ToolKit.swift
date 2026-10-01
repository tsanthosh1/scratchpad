import AppKit

/// Building blocks shared by the dev tool pages.
enum ToolUI {
    static var editorFont: NSFont { .monospacedSystemFont(ofSize: CGFloat(Settings.shared.fontSize), weight: .regular) }

    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    static func caption(_ text: String, size: CGFloat = 12) -> NSTextField {
        let label = NSTextField.label(text, size: size)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = spacing
        row.alignment = .centerY
        return row
    }

    /// A page: views stacked with page margins, each as wide as the page.
    static func page(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return stack
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func describe(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let chars = text.count
        return "\(chars) \(chars == 1 ? "character" : "characters") · \(lines) \(lines == 1 ? "line" : "lines")"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Buttons & controls

/// Icon and/or title button with a 28 pt hit area and hover/pressed states.
/// `.prominent` is filled with the accent colour; `.chip` is an on/off option.
final class ToolActionButton: NSControl {
    enum Style { case plain, prominent, chip }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let style: Style
    private let handler: (ToolActionButton) -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var restore: (title: String, symbol: String?)?
    private var symbol: String?
    var isOn = false { didSet { needsDisplay = true } }

    init(title: String?, symbol: String?, tip: String?, style: Style = .plain, onPress: @escaping (ToolActionButton) -> Void) {
        self.style = style
        handler = onPress
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style == .chip ? 13 : 7
        layer?.cornerCurve = .continuous
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.stringValue = title ?? ""
        label.isHidden = title == nil
        setSymbol(symbol)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        let side: CGFloat = style == .chip ? 11 : 10
        stack.edgeInsets = title == nil ? NSEdgeInsets() : NSEdgeInsets(top: 0, left: side - 1, bottom: 0, right: side + 1)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let height: CGFloat = style == .chip ? 26 : 28
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        if title == nil {
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 30),
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(style == .chip ? .checkBox : .button)
        setAccessibilityLabel(title ?? tip)
    }

    convenience init(title: String?, symbol: String?, tip: String?, style: Style = .plain, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, tip: tip, style: style, onPress: { _ in action() })
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String?) {
        symbol = name
        icon.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = name == nil
    }

    /// Briefly shows a confirmation such as "Copied", then restores the button.
    func flash(title: String = "Copied", symbol: String = "checkmark") {
        if restore == nil { restore = (label.stringValue, self.symbol) }
        if !label.isHidden { label.stringValue = title }
        setSymbol(symbol)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(unflash), object: nil)
        perform(#selector(unflash), with: nil, afterDelay: 1.2)
    }

    @objc private func unflash() {
        guard let restore else { return }
        label.stringValue = restore.title
        setSymbol(restore.symbol)
        self.restore = nil
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        pressed = true
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        guard inside else { return }
        if style == .chip { isOn.toggle() }
        handler(self)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var background: NSColor?
            var border: NSColor?
            let foreground: NSColor
            switch style {
            case .prominent:
                let base = NSColor.controlAccentColor
                background = !isEnabled ? base.withAlphaComponent(0.35)
                    : pressed ? base.blended(withFraction: 0.2, of: .black) : hovering ? base.blended(withFraction: 0.1, of: .white) : base
                foreground = .white
            case .chip:
                let accent = NSColor.controlAccentColor
                if isOn {
                    background = accent.withAlphaComponent(pressed ? 0.3 : hovering ? 0.24 : 0.18)
                    border = accent.withAlphaComponent(0.7)
                    foreground = accent
                } else {
                    background = NSColor.labelColor.withAlphaComponent(pressed ? 0.14 : hovering ? 0.08 : 0.03)
                    border = NSColor.separatorColor
                    foreground = hovering ? .labelColor : .secondaryLabelColor
                }
            case .plain:
                background = !isEnabled ? nil : NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : hovering ? 0.08 : 0)
                foreground = !isEnabled ? .tertiaryLabelColor : hovering ? .labelColor : .secondaryLabelColor
            }
            layer?.backgroundColor = background?.cgColor
            layer?.borderColor = border?.cgColor
            layer?.borderWidth = border == nil ? 0 : 1
            icon.contentTintColor = foreground
            label.textColor = foreground
        }
    }
}

final class ClosurePopUp: NSPopUpButton {
    var onChange: ((Int) -> Void)?

    init(_ titles: [String], selected: Int) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        selectItem(at: titles.indices.contains(selected) ? selected : 0)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange?(indexOfSelectedItem) }
}

final class ClosureSegmented: NSSegmentedControl {
    var onChange: ((Int) -> Void)?

    init(_ titles: [String], selected: Int) {
        super.init(frame: .zero)
        segmentStyle = .rounded
        segmentCount = titles.count
        for (i, title) in titles.enumerated() { setLabel(title, forSegment: i) }
        selectedSegment = titles.indices.contains(selected) ? selected : 0
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange?(selectedSegment) }
}

/// Number field with a stepper beside it.
final class StepperField: NSStackView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let stepper = NSStepper()
    var onChange: ((Int) -> Void)?

    var value: Int {
        get { stepper.integerValue }
        set {
            stepper.integerValue = newValue
            field.stringValue = String(stepper.integerValue)
        }
    }

    init(value: Int, range: ClosedRange<Int>) {
        super.init(frame: .zero)
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        spacing = 2
        addArrangedSubview(field)
        addArrangedSubview(stepper)
        self.value = value
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func stepped() {
        field.stringValue = String(stepper.integerValue)
        onChange?(value)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let number = Int(field.stringValue) else { return }
        stepper.integerValue = number
        onChange?(value)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        field.stringValue = String(stepper.integerValue)
    }
}

/// Small tinted label, e.g. "HS256" or "Expired 2 days ago".
final class Badge: NSView {
    private let label = NSTextField.label("", size: 11)
    private var color: NSColor = .systemGray

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String?, color: NSColor = .systemGray, symbol: String? = nil) {
        isHidden = text == nil
        label.stringValue = (symbol.map { $0 + " " } ?? "") + (text ?? "")
        self.color = color
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
            label.textColor = color
        }
    }
}

// MARK: - Text

/// Text view that reports edits and focus, and fills its card so a click anywhere lands in it.
final class CardTextView: NSTextView {
    var onChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    convenience init(editable: Bool) {
        self.init(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        isEditable = editable
        isSelectable = true
        isRichText = false
        allowsUndo = editable
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = NSSize(width: 10, height: 10)
        drawsBackground = false
        isVerticallyResizable = true
        autoresizingMask = [.width, .height]
        textContainer?.widthTracksTextView = true
        insertionPointColor = .controlAccentColor
        applyFont()
        NotificationCenter.default.addObserver(self, selector: #selector(applyFont), name: .settingsChanged, object: nil)
    }

    @objc private func applyFont() {
        font = ToolUI.editorFont
        typingAttributes[.font] = ToolUI.editorFont
    }

    func setPlaceholder(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: ToolUI.editorFont,
        ])
        if responds(to: NSSelectorFromString("setPlaceholderAttributedString:")) {
            setValue(attributed, forKey: "placeholderAttributedString")
        }
    }

    /// Replaces everything as an undoable edit, as if typed.
    func replaceAll(_ text: String) {
        let range = NSRange(location: 0, length: (string as NSString).length)
        if isEditable, shouldChangeText(in: range, replacementString: text) {
            replaceCharacters(in: range, with: text)
            didChangeText()
        } else {
            string = text
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

// MARK: - Cards

/// Rounded panel: a header with a title and actions, the content, and a footer for counts or an error.
final class ToolCard: NSView {
    var onBackgroundClick: (() -> Void)?
    var isFocused = false { didSet { needsDisplay = true } }
    private var isError = false { didSet { needsDisplay = true } }
    private let meta = NSTextField.label("", size: 11)
    private let metaIcon = NSImageView()

    init(title: String?, content: NSView, actions: [NSView] = [], footer: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        var parts: [NSView] = []
        if title != nil || !actions.isEmpty {
            let titleLabel = NSTextField.label((title ?? "").uppercased(), size: 11)
            titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            let header = NSStackView(views: [titleLabel, ToolUI.spacer()] + actions)
            header.spacing = 2
            header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6)
            header.heightAnchor.constraint(equalToConstant: 38).isActive = true
            let rule = NSBox()
            rule.boxType = .separator
            parts += [header, rule]
        }
        parts.append(content)
        content.setContentHuggingPriority(.init(1), for: .vertical)
        if footer {
            metaIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            metaIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            metaIcon.contentTintColor = .systemRed
            metaIcon.isHidden = true
            meta.textColor = .tertiaryLabelColor
            meta.lineBreakMode = .byTruncatingTail
            meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let bar = NSStackView(views: [metaIcon, meta])
            bar.spacing = 5
            bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
            parts.append(bar)
        }

        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in parts {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A card around a scrolling text view.
    static func text(_ title: String, _ textView: CardTextView, actions: [NSView] = []) -> ToolCard {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        let card = ToolCard(title: title, content: scroll, actions: actions)
        textView.onFocusChange = { [weak card] in card?.isFocused = $0 }
        card.onBackgroundClick = { [weak textView] in textView?.window?.makeFirstResponder(textView) }
        return card
    }

    func setMeta(_ text: String, isError: Bool = false) {
        meta.stringValue = text
        meta.textColor = isError ? .systemRed : .tertiaryLabelColor
        metaIcon.isHidden = !isError
        self.isError = isError
    }

    /// Clicks on the header or footer (not on a button) go to the content.
    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .labelColor)?.cgColor
            let border: NSColor = isError ? .systemRed.withAlphaComponent(0.6)
                : isFocused ? .controlAccentColor.withAlphaComponent(0.8) : .separatorColor
            layer?.borderColor = border.cgColor
            layer?.borderWidth = isFocused || isError ? 1.5 : 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A labelled value; clicking anywhere on the row copies it.
final class ValueRow: NSView {
    private let titleLabel = NSTextField.label("", size: 12)
    private let valueLabel = NSTextField(wrappingLabelWithString: "")
    private let copyIcon = NSImageView()
    private var hovering = false { didSet { updateLook() } }
    var isMatch = false { didSet { updateLook() } }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    var value = "" {
        didSet {
            valueLabel.stringValue = value.isEmpty ? "—" : value
            valueLabel.textColor = value.isEmpty ? .tertiaryLabelColor : .labelColor
            toolTip = value.isEmpty ? nil : "\(value)\n\nClick to copy"
        }
    }

    init(title: String, titleWidth: CGFloat = 130) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        titleLabel.stringValue = title
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.widthAnchor.constraint(equalToConstant: titleWidth).isActive = true
        valueLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 1
        valueLabel.cell?.usesSingleLineMode = true
        valueLabel.isSelectable = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyIcon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        copyIcon.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [titleLabel, valueLabel, copyIcon])
        row.alignment = .firstBaseline
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        value = ""
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard !value.isEmpty else { return NSSound.beep() }
        ToolUI.copy(value)
        copyIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyIcon.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.copyIcon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            self?.updateLook()
        }
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base: NSColor = isMatch ? .systemGreen.withAlphaComponent(0.16) : .labelColor.withAlphaComponent(hovering ? 0.06 : 0)
            layer?.backgroundColor = base.cgColor
        }
        copyIcon.contentTintColor = hovering ? .controlAccentColor : .tertiaryLabelColor
        copyIcon.alphaValue = value.isEmpty ? 0 : 1
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A vertical list that scrolls when it outgrows its card.
final class ScrollStack: NSScrollView {
    let stack = NSStackView()

    init(_ views: [NSView] = [], insets: NSEdgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)) {
        super.init(frame: .zero)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        setViews(views)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setViews(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views {
            stack.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
    }

    /// Height that shows every row without scrolling.
    var fittingHeight: CGFloat { stack.fittingSize.height }
}

/// A big number with a caption, for statistics.
final class StatTile: NSView {
    private let number = NSTextField.label("0", size: 22)
    private let caption = NSTextField.label("", size: 11)

    init(_ title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        number.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        caption.stringValue = title
        caption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [number, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = "Click to copy"
    }

    required init?(coder: NSCoder) { fatalError() }

    var value: String {
        get { number.stringValue }
        set { number.stringValue = newValue }
    }

    override func mouseDown(with event: NSEvent) {
        ToolUI.copy(number.stringValue)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }
}

/// Two panes with an invisible, draggable gap; side by side when wide enough, stacked otherwise.
final class GapSplitView: NSSplitView {
    /// Width at which the panes go side by side; nil keeps `isVertical` as set.
    var sideBySideMinWidth: CGFloat? = 720
    /// Share of the space given to the first pane.
    var ratio: CGFloat = 0.5
    var onOrientationChange: ((Bool) -> Void)?
    private var positioned = false

    override var dividerThickness: CGFloat { 12 }
    override func drawDivider(in rect: NSRect) {}

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, subviews.count == 2 else { return }
        let vertical = sideBySideMinWidth.map { bounds.width >= $0 } ?? isVertical
        guard vertical != isVertical || !positioned else { return }
        positioned = true
        isVertical = vertical
        adjustSubviews()
        let length = vertical ? bounds.width : bounds.height
        setPosition(((length - dividerThickness) * ratio).rounded(), ofDividerAt: 0)
        onOrientationChange?(vertical)
    }
}
