import AppKit

/// The file name shown in the toolbar. Double-click (or the Rename shortcut) turns it into an
/// inline text field; Return commits, Escape cancels.
final class TitleField: NSTextField, NSTextFieldDelegate {
    var onRename: ((String) -> Void)?
    private var original = ""
    private var cancelled = false
    private(set) var isRenaming = false
    /// Off while a dev tool page is showing.
    var isRenamable = true

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 13, weight: .semibold)
        lineBreakMode = .byTruncatingMiddle
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        delegate = self
        toolTip = "Double-click to rename"
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ name: String) {
        guard !isRenaming else { return }
        stringValue = name
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginRename() } else { super.mouseDown(with: event) }
    }

    func beginRename() {
        guard isRenamable, !isRenaming, let window else { return }
        isRenaming = true
        cancelled = false
        original = stringValue
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        window.makeFirstResponder(self)
        // Select the name without the extension, like Finder.
        let stem = (original as NSString).deletingPathExtension
        currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isRenaming else { return }
        isRenaming = false
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        let newName = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cancelled || newName.isEmpty || newName == original {
            stringValue = original
        } else {
            onRename?(newName)
        }
    }
}
