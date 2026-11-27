import AppKit

final class SolidColorView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

final class ConsoleViewController: NSViewController {
    static let terminalBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
            : NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)
    }

    static let terminalHeaderBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
            : NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.93, alpha: 1.0)
    }

    private(set) var textView: NSTextView!
    private let titleLabel = NSTextField.label("Console", size: 11, weight: .semibold, color: .labelColor)
    private let status = StatusPill()
    private let maxLength = 2_000_000
    var onClose: (() -> Void)?
    var onTogglePosition: (() -> Void)?

    private lazy var dockButton = HoverButton(symbol: "sidebar.right", tip: "Dock Console to Right",
                                              target: self, action: #selector(dockClicked), pointSize: 11)

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView = (scroll.documentView as! NSTextView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.drawsBackground = false
        updateFont()

        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.isHidden = true
        let clear = HoverButton(symbol: "trash", tip: "Clear Console", target: self, action: #selector(clearClicked), pointSize: 11)
        let close = HoverButton(symbol: "xmark", tip: "Hide Console", target: self, action: #selector(closeClicked), pointSize: 11)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [icon, titleLabel, status, spacer, clear, dockButton, close])
        header.spacing = 6
        header.setCustomSpacing(8, after: titleLabel)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        header.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let headerContainer = SolidColorView(color: Self.terminalHeaderBackground)
        headerContainer.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ])

        let divider = NSBox()
        divider.boxType = .separator

        let background = SolidColorView(color: Self.terminalBackground)
        let stack = NSStackView(views: [headerContainer, divider, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for v in [headerContainer, divider, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
        setPosition(Settings.shared.consolePosition)
    }

    func updateFont() {
        guard isViewLoaded else { return }
        let size = CGFloat(max(Settings.shared.fontSize - 1, 9))
        textView?.font = NSFont(name: Settings.shared.fontFamily, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func setTitle(_ title: String) {
        _ = view
        titleLabel.stringValue = title
    }

    func setRunning() {
        _ = view
        status.show("Running", color: .controlAccentColor, busy: true)
    }

    func setFinished(exitCode: Int32, elapsed: TimeInterval) {
        _ = view
        let time = elapsed < 1 ? "\(Int((elapsed * 1000).rounded())) ms" : String(format: "%.2f s", elapsed)
        if exitCode == 0 {
            status.show("Exit 0 · \(time)", color: .systemGreen)
        } else if exitCode == -1 {
            status.show("Failed", color: .systemRed)
        } else {
            status.show("Exit \(exitCode) · \(time)", color: .systemRed)
        }
    }

    func setPosition(_ position: ConsolePosition) {
        guard isViewLoaded else { return }
        let isRight = position == .right
        dockButton.image = NSImage(systemSymbolName: isRight ? "sidebar.bottom" : "sidebar.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        dockButton.toolTip = isRight ? "Dock Console to Bottom" : "Dock Console to Right"
    }

    @objc private func dockClicked() {
        onTogglePosition?()
    }

    @objc private func clearClicked() {
        clear()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    func clear() {
        guard isViewLoaded else { return }
        textView.string = ""
        status.isHidden = true
    }

    func append(_ text: String, kind: OutputKind) {
        _ = view
        let color: NSColor
        switch kind {
        case .stdout: color = .textColor
        case .stderr: color = .systemRed
        case .info: color = .secondaryLabelColor
        }
        let font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributed = NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font,
                                                                        .paragraphStyle: paragraph])
        let storage = textView.textStorage!
        let atBottom = isScrolledToBottom
        storage.append(attributed)
        if storage.length > maxLength {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxLength))
        }
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    private var isScrolledToBottom: Bool {
        guard let scroll = textView.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= textView.bounds.height - 20
    }
}
