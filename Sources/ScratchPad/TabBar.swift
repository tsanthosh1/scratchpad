import AppKit

/// Chrome-style tabs for the open files, living in the toolbar: click to switch, drag to reorder, middle-click or ×
/// to close, double-click to rename, right-click for the close-others / close-left / close-right family.
final class TabBarView: NSView {
    struct Tab: Equatable {
        let id: String
        let title: String
        let symbol: String
        let tint: NSColor
        let tip: String
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    var onReorder: (([String]) -> Void)?
    /// The context menu for a tab, or for the empty part of the strip (nil).
    var onMenu: ((String?) -> NSMenu?)?
    var onNew: (() -> Void)?

    private let scroll = HorizontalScrollView()
    fileprivate let strip = TabStripView()
    private var scrollTop: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = false
        scroll.documentView = strip
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            scrollTop,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        strip.bar = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The toolbar centres items in a slot shorter than itself; the tabs reach up into the empty band above
    /// (nothing between here and the window frame clips), so they can be taller than the slot.
    private var reach: CGFloat {
        guard let window, let frameView = window.contentView?.superview else { return 0 }
        return max(0, frameView.bounds.maxY - convert(bounds, to: frameView).maxY)
    }

    /// Bounds plus the band above them that the tabs draw into.
    private var reachBounds: NSRect {
        let reach = -scrollTop.constant
        var rect = bounds
        rect.size.height += reach
        if isFlipped { rect.origin.y -= reach }
        return rect
    }

    override func layout() {
        let reach = reach
        if scrollTop.constant != -reach { scrollTop.constant = -reach }
        super.layout()
        strip.relayout(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard reachBounds.contains(local) else { return nil }
        return scroll.hitTest(local) ?? self
    }

    private var menuMonitor: Any?

    /// The toolbar claims right-clicks in its area before they reach the tabs, so they're picked off here first.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let menuMonitor { NSEvent.removeMonitor(menuMonitor) }
        menuMonitor = nil
        guard window != nil else { return }
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  window.attachedSheet == nil,
                  self.reachBounds.contains(self.convert(event.locationInWindow, from: nil)),
                  let (menu, view) = self.strip.contextMenu(at: event.locationInWindow) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        }
    }

    func setTabs(_ tabs: [Tab], active: String?) {
        strip.update(tabs, active: active)
    }
}

/// Turns a plain mouse wheel into horizontal scrolling, so a long row of tabs can be scrolled without a trackpad.
private final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let cg = event.cgEvent?.copy() else {
            return super.scrollWheel(with: event)
        }
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        super.scrollWheel(with: NSEvent(cgEvent: cg) ?? event)
    }
}

private enum TabMetrics {
    /// Radius of the curves where the active tab flares into the content below; tabs keep this much room each side.
    static let foot: CGFloat = 8
    static let corner: CGFloat = 8
    static let topInset: CGFloat = 6
    static let minWidth: CGFloat = 92
    static let maxWidth: CGFloat = 230
    static let newButtonWidth: CGFloat = 30
}

private final class TabStripView: NSView {
    weak var bar: TabBarView?
    private var items: [TabItemView] = []
    private var activeId: String?
    private var dragging: TabItemView?
    private lazy var newButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Scratch")!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!, target: self, action: #selector(newClicked))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "New Scratch"
        addSubview(button)
        return button
    }()

    override var isFlipped: Bool { true }

    func update(_ tabs: [TabBarView.Tab], active: String?) {
        var reusable = Dictionary(items.map { ($0.tab.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [TabItemView] = []
        for tab in tabs {
            let item = reusable.removeValue(forKey: tab.id) ?? {
                let item = TabItemView(tab: tab)
                item.strip = self
                addSubview(item, positioned: .below, relativeTo: nil)
                return item
            }()
            item.tab = tab
            item.isActive = tab.id == active
            next.append(item)
        }
        reusable.values.forEach { $0.removeFromSuperview() }
        let activeChanged = activeId != active
        items = next
        activeId = active
        // The active tab draws over its neighbours' separators.
        if let activeItem = items.first(where: { $0.isActive }) { addSubview(activeItem, positioned: .above, relativeTo: nil) }
        relayout(animated: false)
        if activeChanged, let item = items.first(where: { $0.isActive }) {
            DispatchQueue.main.async { self.scrollToVisible(item.frame) }
        }
    }

    /// Like Chrome: every tab gets the same width, shrinking as tabs are added until they have to scroll.
    private var tabWidth: CGFloat {
        let available = (superview?.bounds.width ?? 0) - TabMetrics.newButtonWidth
        guard !items.isEmpty else { return TabMetrics.maxWidth }
        // Neighbouring tabs share the space reserved for their curves.
        let fit = (available - TabMetrics.foot) / CGFloat(items.count) + TabMetrics.foot
        return min(max(floor(fit), TabMetrics.minWidth), TabMetrics.maxWidth)
    }

    private func x(at index: Int, width: CGFloat) -> CGFloat { CGFloat(index) * (width - TabMetrics.foot) }

    func relayout(animated: Bool) {
        let height = superview?.bounds.height ?? bounds.height
        let width = tabWidth
        let tabsEnd = items.isEmpty ? 0 : x(at: items.count, width: width) + TabMetrics.foot
        setFrameSize(NSSize(width: max(tabsEnd + TabMetrics.newButtonWidth, superview?.bounds.width ?? 0), height: height))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            context.allowsImplicitAnimation = animated
            for (index, item) in items.enumerated() where item !== dragging {
                let frame = NSRect(x: x(at: index, width: width), y: 0, width: width, height: height)
                if animated { item.animator().frame = frame } else { item.frame = frame }
            }
        }
        let bodyMid = TabMetrics.topInset + (height - TabMetrics.topInset) / 2
        newButton.frame = NSRect(x: tabsEnd + 2, y: bodyMid - 12, width: 24, height: 24)
        updateSeparators()
    }

    /// Separators sit between resting tabs only; they vanish next to the active or hovered tab, as in Chrome.
    func updateSeparators() {
        for (index, item) in items.enumerated() {
            let next = items.indices.contains(index + 1) ? items[index + 1] : nil
            item.showsSeparator = next != nil && !item.isHighlighted && !(next?.isHighlighted ?? false)
        }
    }

    /// Click selects, dragging past a few points reorders (the other tabs slide out of the way).
    func track(_ item: TabItemView, from event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 { return bar?.onRename?(item.tab.id) ?? () }
        let start = convert(event.locationInWindow, from: nil)
        let grabOffset = start.x - item.frame.minX
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            if !moved, abs(point.x - start.x) < 4 { continue }
            if !moved {
                moved = true
                dragging = item
                addSubview(item, positioned: .above, relativeTo: nil)
                if !item.isActive { bar?.onSelect?(item.tab.id) }
            }
            let maxX = x(at: items.count - 1, width: item.frame.width)
            item.frame.origin.x = max(0, min(maxX, point.x - grabOffset))
            autoscroll(with: next)
            guard let from = items.firstIndex(where: { $0 === item }) else { continue }
            let stride = item.frame.width - TabMetrics.foot
            let target = min(max(Int((item.frame.minX / stride).rounded()), 0), items.count - 1)
            if target != from {
                items.remove(at: from)
                items.insert(item, at: target)
                relayout(animated: true)
            }
        }
        guard moved else { return bar?.onSelect?(item.tab.id) ?? () }
        dragging = nil
        relayout(animated: true)
        bar?.onReorder?(items.map(\.tab.id))
    }

    func close(_ item: TabItemView) { bar?.onClose?(item.tab.id) }
    func menu(for item: TabItemView) -> NSMenu? { bar?.onMenu?(item.tab.id) }
    @objc private func newClicked() { bar?.onNew?() }

    /// The menu for whatever is under a window point: the tab's own menu, else the strip's.
    func contextMenu(at windowPoint: NSPoint) -> (NSMenu, NSView)? {
        let point = convert(windowPoint, from: nil)
        if let item = items.last(where: { $0.frame.contains(point) && $0.hitTest(point) != nil }) {
            return menu(for: item).map { ($0, item) }
        }
        return bar?.onMenu?(nil).map { ($0, self) }
    }

    /// The empty part of the strip behaves like the title bar: drag moves the window, double-click zooms it.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

private final class TabItemView: NSView {
    weak var strip: TabStripView?
    var tab: TabBarView.Tab { didSet { if tab != oldValue { refresh() } } }
    var isActive = false { didSet { if isActive != oldValue { refresh() } } }
    var showsSeparator = false { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    var isHighlighted: Bool { isActive || isHovered }
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            refresh()
            strip?.updateSeparators()
        }
    }
    private let icon = NSImageView()
    private let label = NSTextField.label("", size: 12)
    private let closeButton = TabCloseButton()

    init(tab: TabBarView.Tab) {
        self.tab = tab
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        [icon, label, closeButton].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        label.stringValue = tab.title
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        icon.contentTintColor = isActive || isHovered ? tab.tint : tab.tint.withAlphaComponent(0.65)
        toolTip = tab.tip
        closeButton.isHidden = !(isActive || isHovered) && bounds.width < 140
        needsDisplay = true
        needsLayout = true
    }

    /// The tab's area between its curved feet, from just below the top of the strip to the bottom edge.
    private var body: NSRect {
        NSRect(x: TabMetrics.foot, y: TabMetrics.topInset,
               width: bounds.width - 2 * TabMetrics.foot, height: bounds.height - TabMetrics.topInset)
    }

    override func layout() {
        super.layout()
        let body = body
        let mid = body.midY
        icon.frame = NSRect(x: body.minX + 10, y: mid - 8, width: 16, height: 16)
        closeButton.frame = NSRect(x: body.maxX - 24, y: mid - 8, width: 16, height: 16)
        let labelHeight = label.intrinsicContentSize.height
        let labelEnd = closeButton.isHidden ? body.maxX - 8 : closeButton.frame.minX - 4
        label.frame = NSRect(x: icon.frame.maxX + 6, y: mid - labelHeight / 2,
                             width: max(0, labelEnd - icon.frame.maxX - 6), height: labelHeight)
        closeButton.isHidden = !(isActive || isHovered) && bounds.width < 140
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = body
        if isActive {
            Self.activeShape(in: bounds, body: body).fill(with: .windowBackgroundColor)
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 3), xRadius: TabMetrics.corner, yRadius: TabMetrics.corner).fill()
        }
        if showsSeparator {
            NSColor.separatorColor.setFill()
            let height = body.height * 0.5
            NSRect(x: bounds.width - TabMetrics.foot - 0.5, y: body.midY - height / 2, width: 1, height: height).fill()
        }
    }

    /// Rounded top corners, and feet that curve outwards into the content below so the tab and the page read as one.
    private static func activeShape(in bounds: NSRect, body: NSRect) -> NSBezierPath {
        let foot = TabMetrics.foot, corner = TabMetrics.corner, k: CGFloat = 0.45
        let bottom = bounds.maxY, top = body.minY, left = body.minX, right = body.maxX
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left - foot, y: bottom))
        path.curve(to: NSPoint(x: left, y: bottom - foot),
                   controlPoint1: NSPoint(x: left - foot * k, y: bottom), controlPoint2: NSPoint(x: left, y: bottom - foot * k))
        path.line(to: NSPoint(x: left, y: top + corner))
        path.curve(to: NSPoint(x: left + corner, y: top),
                   controlPoint1: NSPoint(x: left, y: top + corner * k), controlPoint2: NSPoint(x: left + corner * k, y: top))
        path.line(to: NSPoint(x: right - corner, y: top))
        path.curve(to: NSPoint(x: right, y: top + corner),
                   controlPoint1: NSPoint(x: right - corner * k, y: top), controlPoint2: NSPoint(x: right, y: top + corner * k))
        path.line(to: NSPoint(x: right, y: bottom - foot))
        path.curve(to: NSPoint(x: right + foot, y: bottom),
                   controlPoint1: NSPoint(x: right, y: bottom - foot * k), controlPoint2: NSPoint(x: right + foot * k, y: bottom))
        path.close()
        return path
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return body.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { strip?.track(self, from: event) }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { strip?.close(self) }
    }


    @objc private func closeClicked() { strip?.close(self) }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

/// Chrome's close glyph: an × that gets a round backdrop on hover.
private final class TabCloseButton: NSButton {
    private var isHovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        super.draw(dirtyRect)
    }
}
