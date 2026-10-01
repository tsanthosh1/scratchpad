import AppKit

/// Short-lived, non-interactive notice floating near the bottom of a window.
/// Lives in a child window so it sits above the web view without joining the split view layout.
@MainActor
final class Toast {
    private static var current: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", tint: NSColor = .systemGreen,
                     in parent: NSWindow?, duration: TimeInterval = 2.4) {
        guard let parent else { return }
        dismiss(animated: false)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        icon.contentTintColor = tint

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: min(520, parent.frame.width - 80)),
        ])

        let size = background.fittingSize
        let frame = NSRect(x: parent.frame.midX - size.width / 2, y: parent.frame.minY + 48,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = background
        panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        current = panel

        let work = DispatchWorkItem { dismiss(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func dismiss(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        guard let panel = current else { return }
        current = nil
        let close = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        guard animated else { return close() }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { close() } })
    }
}
