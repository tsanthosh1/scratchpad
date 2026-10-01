import AppKit

/// Shows the page of the selected dev tool. Pages are kept, so switching back finds them as left.
final class DevToolViewController: NSViewController {
    /// Asks the window to open text in a new scratch.
    var onOpenInScratch: ((String) -> Void)?

    private(set) var tool: DevTool?
    private var pages: [String: ToolPageController] = [:]
    private var current: ToolPageController?

    override func loadView() {
        let root = KeyView()
        root.onKeyEquivalent = { [weak self] event in self?.handleKey(event) ?? false }
        view = root
    }

    func load(_ tool: DevTool) {
        _ = view
        self.tool = tool
        let page = pages[tool.id] ?? tool.makePage()
        pages[tool.id] = page
        page.onOpenInScratch = { [weak self] text in self?.onOpenInScratch?(text) }
        guard page !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(page)
        page.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.view.topAnchor.constraint(equalTo: view.topAnchor),
            page.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = page
    }

    func focusInput() {
        current?.focus()
    }

    /// ⌘⇧C copies the page's main result from anywhere on it.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c",
              let output = current?.primaryOutput, !output.isEmpty else { return false }
        ToolUI.copy(output)
        return true
    }
}

private final class KeyView: NSView {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}
