import AppKit

/// Shared look for toolbar controls: 28 pt tall, rounded, same symbol size and weight everywhere.
enum ToolbarStyle {
    static let height: CGFloat = 28
    static let buttonWidth: CGFloat = 32
    static let symbolSize: CGFloat = 13
    static let corner: CGFloat = 8
    /// Controls in the row under the toolbar: shorter, and without the capsule until hovered.
    static let compactHeight: CGFloat = 22

    static func button(symbol: String, tip: String, target: AnyObject?, action: Selector?) -> HoverButton {
        let b = HoverButton(symbol: symbol, tip: tip, target: target, action: action, pointSize: symbolSize)
        b.constraints.filter { $0.firstAttribute == .width || $0.firstAttribute == .height }.forEach { $0.isActive = false }
        b.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
        b.heightAnchor.constraint(equalToConstant: height - 4).isActive = true
        b.layer?.cornerRadius = corner - 2
        return b
    }

    @discardableResult
    static func makeCompact(_ b: HoverButton) -> HoverButton {
        b.constraints.filter { $0.firstAttribute == .width || $0.firstAttribute == .height }.forEach { $0.isActive = false }
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: compactHeight).isActive = true
        b.layer?.cornerRadius = 6
        b.image = b.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        return b
    }
}

/// A capsule holding related toolbar buttons, like a segmented control without the chrome of one.
final class ToolbarGroup: NSView {
    private let stack = NSStackView()
    private let compact: Bool

    init(_ views: [NSView], compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ToolbarStyle.corner
        layer?.cornerCurve = .continuous
        layer?.borderWidth = compact ? 0 : 0.5
        stack.spacing = 1
        stack.edgeInsets = compact ? NSEdgeInsets() : NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: compact ? ToolbarStyle.compactHeight : ToolbarStyle.height),
        ])
        setViews(views)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setViews(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(stack.addArrangedSubview)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = compact ? nil : NSColor.labelColor.withAlphaComponent(0.045).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
    }
}

/// Toolbar pill that shows a tinted file-type icon, a title and a chevron, and opens a menu on click.
final class ToolbarMenuButton: NSControl {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    var onClick: ((ToolbarMenuButton) -> Void)?
    private let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = compact ? 6 : ToolbarStyle.corner
        layer?.cornerCurve = .continuous
        layer?.borderWidth = compact ? 0 : 0.5
        label.font = .systemFont(ofSize: compact ? 11.5 : 12, weight: compact ? .regular : .medium)
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, label, chevron])
        stack.spacing = compact ? 5 : 6
        stack.setCustomSpacing(compact ? 5 : 8, after: label)
        stack.edgeInsets = compact ? NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 6)
                                   : NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: compact ? ToolbarStyle.compactHeight : ToolbarStyle.height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 0 : 116),
        ])
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ language: Language) {
        show(symbol: language.symbolName, tint: language.tint, title: language.displayName,
             accessibility: "Language: \(language.displayName)")
    }

    func show(symbol: String, tint: NSColor, title: String, accessibility: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: compact ? 11 : ToolbarStyle.symbolSize, weight: .medium)
                .applying(.init(paletteColors: [tint])))
        label.stringValue = title
        setAccessibilityLabel(accessibility)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        onClick?(self)
        pressed = false
        hovering = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = pressed ? 0.14 : hovering ? 0.09 : compact ? 0 : 0.045
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        label.textColor = !isEnabled ? .tertiaryLabelColor : compact ? .secondaryLabelColor : .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
