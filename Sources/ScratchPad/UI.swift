import AppKit

// Shared building blocks so every panel gets the same hover, press and sizing behaviour.

extension Language {
    /// Accent used for the file-type tile in lists and the status bar.
    var tint: NSColor {
        switch self {
        case .json: return .systemYellow
        case .xml: return .systemOrange
        case .html: return .systemRed
        case .markdown: return .systemBlue
        case .richtext: return NSColor(red: 0.85, green: 0.3, blue: 0.55, alpha: 1)
        case .csv: return NSColor(red: 0.13, green: 0.6, blue: 0.35, alpha: 1)
        case .tsv: return NSColor(red: 0.1, green: 0.55, blue: 0.55, alpha: 1)
        case .http: return .systemGreen
        case .diff: return .systemOrange
        case .javascript: return NSColor(red: 0.85, green: 0.72, blue: 0.1, alpha: 1)
        case .typescript: return NSColor(red: 0.19, green: 0.47, blue: 0.78, alpha: 1)
        case .java: return NSColor(red: 0.85, green: 0.35, blue: 0.2, alpha: 1)
        case .python: return NSColor(red: 0.22, green: 0.46, blue: 0.69, alpha: 1)
        case .shell: return .systemGray
        case .css: return .systemPurple
        case .sql: return .systemTeal
        case .yaml: return .systemPink
        case .openapi: return NSColor(red: 0.42, green: 0.66, blue: 0.13, alpha: 1)
        case .toml: return .systemBrown
        case .properties: return .systemIndigo
        case .kotlin: return NSColor(red: 0.5, green: 0.36, blue: 0.95, alpha: 1)
        case .go: return .systemCyan
        case .rust: return NSColor(red: 0.72, green: 0.4, blue: 0.25, alpha: 1)
        case .cpp: return NSColor(red: 0.2, green: 0.4, blue: 0.75, alpha: 1)
        case .text: return .systemGray
        }
    }
}

/// Rounded, tinted tile with an SF Symbol — used for file types and palette categories.
final class SymbolTile: NSView {
    private let imageView = NSImageView()
    private let side: CGFloat

    init(side: CGFloat = 22) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = side * 0.28
        layer?.cornerCurve = .continuous
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = .init(pointSize: side * 0.52, weight: .semibold)
        addSubview(imageView)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tint: NSColor = .systemGray

    func configure(symbol: String, tint: NSColor) {
        self.tint = tint
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
        updateColors()
    }

    func configure(_ language: Language) {
        configure(symbol: language.symbolName, tint: language.tint)
    }

    /// On a selected (accent-filled) row the tile turns white-on-translucent so it stays readable.
    var isOnSelection = false { didSet { updateColors() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isOnSelection {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
                imageView.contentTintColor = .white
            } else {
                layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
                imageView.contentTintColor = tint
            }
        }
    }
}

/// Borderless icon (or icon + title) button with hover, pressed and "on" states.
final class HoverButton: NSButton {
    private var hovering = false { didSet { updateLook() } }
    private var trackingArea: NSTrackingArea?
    /// Toggle buttons show an accent background while on.
    var isToggle = false { didSet { setButtonType(isToggle ? .pushOnPushOff : .momentaryPushIn); updateLook() } }
    var accentWhenOn: NSColor = .controlAccentColor
    /// Fixed icon colour while enabled (e.g. green Run); nil uses the neutral label colours.
    var semanticTint: NSColor? { didSet { updateLook() } }

    convenience init(symbol: String, tip: String, target: AnyObject?, action: Selector?, pointSize: CGFloat = 13) {
        self.init(frame: .zero)
        setup()
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        imagePosition = .imageOnly
        toolTip = tip
        self.target = target
        self.action = action
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    convenience init(title: String, symbol: String? = nil, tip: String?, target: AnyObject?, action: Selector?,
                     font: NSFont = .systemFont(ofSize: 11, weight: .medium)) {
        self.init(frame: .zero)
        setup()
        self.title = title
        self.font = font
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        toolTip = tip
        self.target = target
        self.action = action
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func setup() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .none
        updateLook()
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if !title.isEmpty { size.width += 14 }
        return size
    }

    override var isHighlighted: Bool { didSet { updateLook() } }
    override var isEnabled: Bool { didSet { updateLook() } }
    override var state: NSControl.StateValue { didSet { updateLook() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovering = false
    }

    private func updateLook() {
        let on = isToggle && state == .on
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            if !isEnabled {
                background = .clear
            } else if on {
                background = accentWhenOn.withAlphaComponent(isHighlighted ? 0.32 : hovering ? 0.24 : 0.16)
            } else {
                background = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : hovering ? 0.08 : 0)
            }
            layer?.backgroundColor = background.cgColor
        }
        contentTintColor = !isEnabled ? .tertiaryLabelColor : on ? accentWhenOn
            : semanticTint ?? (hovering ? .labelColor : .secondaryLabelColor)
        if !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? .systemFont(ofSize: 11),
                .foregroundColor: contentTintColor ?? .labelColor,
            ])
        }
    }
}

/// Table row with a subtle hover highlight and, optionally, a rounded accent selection.
final class HoverRowView: NSTableRowView {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    /// Source lists keep the native selection; floating panels draw their own rounded one.
    var drawsRoundedSelection = true
    var inset: CGFloat = 6
    /// Draws the selection in the muted, unfocused style, e.g. while a cell is being edited inline.
    var isQuiet = false {
        didSet { if isQuiet != oldValue { needsDisplay = true; subviews.forEach { $0.needsDisplay = true } } }
    }

    private var floatingBackground: NSView?

    /// Pinned section headers need an opaque backing, or the rows scrolling underneath show through.
    override var isFloating: Bool {
        didSet {
            guard isFloating != oldValue else { return }
            if isFloating {
                let material = NSVisualEffectView(frame: bounds)
                material.material = .sidebar
                material.blendingMode = .behindWindow
                material.state = .followsWindowActiveState
                material.autoresizingMask = [.width, .height]
                let hairline = NSBox(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 1))
                hairline.boxType = .separator
                hairline.autoresizingMask = [.width, .maxYMargin]
                material.addSubview(hairline)
                addSubview(material, positioned: .below, relativeTo: nil)
                floatingBackground = material
            } else {
                floatingBackground?.removeFromSuperview()
                floatingBackground = nil
            }
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isQuiet && isSelected ? .normal : super.interiorBackgroundStyle
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        // Also runs while scrolling; rows sliding under a still cursor don't reliably get mouseExited.
        syncWithMouse()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        for case let row as HoverRowView in superview?.subviews ?? [] where row !== self {
            row.syncWithMouse()
        }
    }

    override func mouseExited(with event: NSEvent) { hovering = false }

    private func syncWithMouse() {
        guard let window, window.isVisible, let clip = enclosingScrollView?.contentView else {
            hovering = false
            return
        }
        let point = window.mouseLocationOutsideOfEventStream
        hovering = bounds.contains(convert(point, from: nil)) && clip.bounds.contains(clip.convert(point, from: nil))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    private var highlightRect: NSRect {
        bounds.insetBy(dx: inset, dy: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovering, !isSelected, !isGroupRowStyle else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isQuiet {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6).fill()
            return
        }
        guard drawsRoundedSelection else { return super.drawSelection(in: dirtyRect) }
        let color: NSColor = isEmphasized ? .controlAccentColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6).fill()
    }
}

/// Renders a shortcut such as "⌥⌘L" as individual keycaps.
final class KeycapsView: NSStackView {
    var onSelection = false { didSet { rebuild() } }
    private var keys: [String] = []

    init() {
        super.init(frame: .zero)
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ shortcut: String?) {
        keys = Self.split(shortcut ?? "")
        rebuild()
    }

    /// "⌥⇧⌘L" → ["⌥", "⇧", "⌘", "L"]; words such as "esc" or "F2" stay together.
    static func split(_ shortcut: String) -> [String] {
        var keys: [String] = []
        var word = ""
        for ch in shortcut {
            if "⌃⌥⇧⌘".contains(ch) {
                if !word.isEmpty { keys.append(word); word = "" }
                keys.append(String(ch))
            } else if ch == " " {
                if !word.isEmpty { keys.append(word); word = "" }
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { keys.append(word) }
        return keys
    }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in keys {
            let label = NSTextField(labelWithString: key)
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.alignment = .center
            label.textColor = onSelection ? .white : .secondaryLabelColor
            let cap = NSView()
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 4
            cap.layer?.borderWidth = 0.5
            effectiveAppearance.performAsCurrentDrawingAppearance {
                cap.layer?.backgroundColor = (onSelection ? NSColor.white.withAlphaComponent(0.2)
                                              : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
                cap.layer?.borderColor = (onSelection ? NSColor.white.withAlphaComponent(0.3)
                                          : NSColor.labelColor.withAlphaComponent(0.14)).cgColor
            }
            label.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(label)
            cap.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cap.heightAnchor.constraint(equalToConstant: 17),
                cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
                label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            ])
            addArrangedSubview(cap)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }
}

/// Capsule with a coloured dot (or spinner) and a short label, e.g. "Exit 0 · 0.42 s".
final class StatusPill: NSView {
    private let dot = NSView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var color: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        let stack = NSStackView(views: [spinner, dot, label])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            spinner.widthAnchor.constraint(equalToConstant: 10),
            spinner.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, color: NSColor, busy: Bool = false) {
        isHidden = false
        self.color = color
        label.stringValue = text
        label.textColor = color
        spinner.isHidden = !busy
        dot.isHidden = busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
            dot.layer?.backgroundColor = color.cgColor
        }
    }
}

extension NSTextField {
    static func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// Menu item that runs a closure, for menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
