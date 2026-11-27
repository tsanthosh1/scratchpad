import AppKit
import UniformTypeIdentifiers

/// Reading and writing rich text scratches. `.rtfd` packages keep images; `.rtf` files hold text only.
enum RichTextIO {
    static let bodySize: CGFloat = 16

    static var defaultParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        style.paragraphSpacing = 6
        return style
    }

    /// Black rather than a dynamic colour: the page maps colours for Dark Mode, and the file stays
    /// readable in TextEdit.
    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.black, .paragraphStyle: defaultParagraph]
    }

    static func isPackage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "rtfd" }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: defaultAttributes)
    }

    static func load(_ url: URL) -> NSAttributedString? {
        let type: NSAttributedString.DocumentType = isPackage(url) ? .rtfd : .rtf
        guard let text = try? NSMutableAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else {
            return nil
        }
        adoptImages(in: text, sizes: isPackage(url) ? savedImageSizes(url) : [:])
        return text
    }

    static func write(_ text: NSAttributedString, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        if isPackage(url) {
            let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        } else {
            let data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: url, options: .atomic)
        }
    }

    /// AppKit writes each image's displayed size (`\width`/`\height`, in twips) but ignores it when reading.
    private static func savedImageSizes(_ url: URL) -> [String: NSSize] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("TXT.rtf")),
              let rtf = String(data: data, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: #"\\NeXTGraphic (.+?) \\width(\d+) \\height(\d+)"#) else { return [:] }
        let ns = rtf as NSString
        var sizes: [String: NSSize] = [:]
        for match in regex.matches(in: rtf, range: NSRange(location: 0, length: ns.length)) {
            let width = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let height = Double(ns.substring(with: match.range(at: 3))) ?? 0
            if width > 0, height > 0 {
                sizes[ns.substring(with: match.range(at: 1))] = NSSize(width: width / 20, height: height / 20)
            }
        }
        return sizes
    }

    /// Gives every image attachment a resizable cell, at its saved size when there is one.
    private static func adoptImages(in text: NSMutableAttributedString, sizes: [String: NSSize]) {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let image = image(of: attachment) else { return }
            let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename
            attachment.attachmentCell = ImageAttachmentCell(image: image, size: name.flatMap { sizes[$0] } ?? image.size)
        }
    }

    static func image(of attachment: NSTextAttachment) -> NSImage? {
        if let cell = attachment.attachmentCell as? ImageAttachmentCell { return cell.image }
        if let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data) { return image }
        return attachment.image
    }

    /// A new attachment holding the image as PNG (JPEG stays JPEG), sized to fit `maxWidth`.
    static func attachment(for image: NSImage, data: Data?, maxWidth: CGFloat) -> NSTextAttachment {
        let isJPEG = data.map { $0.starts(with: [0xFF, 0xD8]) } ?? false
        let isPNG = data.map { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) } ?? false
        let contents: Data
        if let data, isJPEG || isPNG {
            contents = data
        } else if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            contents = png
        } else {
            contents = data ?? Data()
        }
        let wrapper = FileWrapper(regularFileWithContents: contents)
        let id = UUID().uuidString.prefix(8).lowercased()
        wrapper.preferredFilename = "image-\(id).\(isJPEG ? "jpg" : "png")"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.attachmentCell = ImageAttachmentCell(image: image, size: fit(image.size, maxWidth: maxWidth))
        return attachment
    }

    static func fit(_ size: NSSize, maxWidth: CGFloat) -> NSSize {
        guard size.width > maxWidth, size.width > 0 else { return size }
        return NSSize(width: maxWidth.rounded(), height: (size.height * maxWidth / size.width).rounded())
    }
}

/// Draws an image attachment at any size; the size is what RTFD saves as the image's width and height.
final class ImageAttachmentCell: NSTextAttachmentCell {
    var displaySize: NSSize

    init(image: NSImage, size: NSSize) {
        displaySize = size
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        displaySize = .zero
        super.init(coder: coder)
    }

    var naturalSize: NSSize { image?.size ?? displaySize }

    override func cellSize() -> NSSize { displaySize }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func wantsToTrackMouse() -> Bool { false }
    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?,
                                    atCharacterIndex charIndex: Int) -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

/// Text view that selects images on click and resizes them by dragging a corner handle.
final class RichTextView: NSTextView {
    static let columnWidth: CGFloat = 760
    static let pagePaddingX: CGFloat = 36
    static let pagePaddingY: CGFloat = 28

    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
            : NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.95, alpha: 1.0)
    }

    static let pageColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
            : NSColor.white
    }

    static let pageBorderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1.0, alpha: 0.10)
            : NSColor(calibratedWhite: 0.0, alpha: 0.12)
    }

    var onConvertToBullet: (() -> Void)?

    var pageRect: NSRect {
        let pw = min(Self.columnWidth, max(300, bounds.width - 48))
        let px = max(24, ((bounds.width - pw) / 2).rounded())
        let topMargin: CGFloat = 20
        let bottomMargin: CGFloat = 40
        let used = layoutManager?.usedRect(for: textContainer ?? NSTextContainer()).height ?? 0
        let minHeight = max(bounds.height - topMargin - bottomMargin, 500)
        let neededHeight = textContainerInset.height + used + 60
        let ph = max(minHeight, neededHeight)
        return NSRect(x: px, y: topMargin, width: pw, height: ph)
    }

    private static let handleSize: CGFloat = 9
    private var resizeLabel: String?
    private var lastImageRect: NSRect?

    /// Index of the selected image when the selection is exactly one image.
    var selectedImageIndex: Int? {
        let range = selectedRange()
        guard range.length == 1, imageCell(at: range.location) != nil else { return nil }
        return range.location
    }

    var maxImageWidth: CGFloat {
        max(40, (pageRect.width - 2 * Self.pagePaddingX) - 2 * (textContainer?.lineFragmentPadding ?? 5) - 2)
    }

    func imageCell(at index: Int) -> ImageAttachmentCell? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return (storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?
            .attachmentCell as? ImageAttachmentCell
    }

    func imageRect(at index: Int) -> NSRect? {
        guard let layoutManager, let textContainer, imageCell(at: index) != nil else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        let size = layoutManager.attachmentSize(forGlyphAt: glyph)
        guard size.width > 0 else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: origin.x + line.minX + location.x, y: origin.y + line.minY + location.y - size.height,
                      width: size.width, height: size.height)
    }

    private func handleRects(_ rect: NSRect) -> [NSRect] {
        let s = Self.handleSize
        return [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)]
            .map { NSRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    private func imageIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard let rect = imageRect(at: index), rect.contains(point) else { return nil }
        return index
    }

    // MARK: Selection outline

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        refreshImageOutline()
    }

    func refreshImageOutline() {
        let rect = selectedImageIndex.flatMap(imageRect(at:))
        if let old = lastImageRect { setNeedsDisplay(old.insetBy(dx: -40, dy: -30)) }
        if let rect { setNeedsDisplay(rect.insetBy(dx: -40, dy: -30)) }
        lastImageRect = rect
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pr = pageRect
        let path = NSBezierPath(roundedRect: pr, xRadius: 8, yRadius: 8)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        Self.pageColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        Self.pageColor.setFill()
        path.fill()

        Self.pageBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        super.draw(dirtyRect)

        guard let index = selectedImageIndex, let rect = imageRect(at: index) else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2
        outline.stroke()
        for handle in handleRects(rect) {
            let p = NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            p.fill()
            p.lineWidth = 1.5
            p.stroke()
        }
        if let resizeLabel {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
            ]
            let size = (resizeLabel as NSString).size(withAttributes: attributes)
            let box = NSRect(x: rect.maxX - size.width - 14, y: rect.maxY - size.height - 12,
                             width: size.width + 10, height: size.height + 4)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            (resizeLabel as NSString).draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attributes)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let index = selectedImageIndex, let rect = imageRect(at: index) else { return }
        addCursorRect(rect, cursor: .arrow)
        for handle in handleRects(rect) { addCursorRect(handle.insetBy(dx: -3, dy: -3), cursor: .crosshair) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = selectedImageIndex, let rect = imageRect(at: index),
           let corner = handleRects(rect).firstIndex(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            return resizeImage(at: index, corner: corner, from: point)
        }
        if event.clickCount == 1, !event.modifierFlags.contains(.shift), let index = imageIndex(at: point) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: index, length: 1))
            return
        }

        // Checklist checkbox click detection
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 {
            let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            var fraction: CGFloat = 0
            let glyph = layoutManager.glyphIndex(for: p, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
            let ns = storage.string as NSString
            if charIndex < ns.length {
                let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                if glyphRect.insetBy(dx: -4, dy: -4).contains(p) {
                    let ch = ns.substring(with: NSRange(location: charIndex, length: 1))
                    if ch == "☐" || ch == "☑" {
                        let isChecking = (ch == "☐")
                        let newMarker = isChecking ? "☑" : "☐"
                        let targetRange = NSRange(location: charIndex, length: 1)
                        if shouldChangeText(in: targetRange, replacementString: newMarker) {
                            storage.replaceCharacters(in: targetRange, with: newMarker)

                            // Find rest of line to apply/remove strikethrough
                            let paraRange = ns.paragraphRange(for: targetRange)
                            let afterMarker = charIndex + 1 + (charIndex + 1 < ns.length && ns.substring(with: NSRange(location: charIndex + 1, length: 1)) == " " ? 1 : 0)
                            let paraEnd = NSMaxRange(paraRange)
                            let lineEnd = paraEnd > 0 && ns.substring(with: NSRange(location: paraEnd - 1, length: 1)) == "\n" ? paraEnd - 1 : paraEnd
                            if afterMarker < lineEnd {
                                let textRange = NSRange(location: afterMarker, length: lineEnd - afterMarker)
                                if isChecking {
                                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: textRange)
                                } else {
                                    storage.removeAttribute(.strikethroughStyle, range: textRange)
                                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: textRange)
                                }
                            }

                            didChangeText()
                            window?.makeFirstResponder(self)
                            return
                        }
                    }
                }
            }
        }

        super.mouseDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let str = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let selected = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        let ns = (textStorage?.string ?? "") as NSString
        let lineRange = selected.location <= ns.length ? ns.paragraphRange(for: selected) : NSRange(location: 0, length: 0)
        let prefixBefore = selected.location >= lineRange.location
            ? ns.substring(with: NSRange(location: lineRange.location, length: selected.location - lineRange.location))
            : ""
        let fullPrefix = prefixBefore + str

        // Confluence shortcut 1: "- " or "* " at start of paragraph -> Bullet list
        if (str == " " || str == "\t") && (prefixBefore == "-" || prefixBefore == "*") {
            super.insertText("", replacementRange: NSRange(location: lineRange.location, length: prefixBefore.count))
            onConvertToBullet?()
            return
        }

        // Confluence shortcut 2: "[]" or "[ ]" or "[] " or "[ ] " at start of paragraph -> Checklist item "☐ "
        if fullPrefix == "[]" || fullPrefix == "[ ]" || fullPrefix == "[] " || fullPrefix == "[ ] " {
            let replaceLen = prefixBefore.count + (replacementRange.location != NSNotFound ? replacementRange.length : 0)
            super.insertText("☐ ", replacementRange: NSRange(location: lineRange.location, length: replaceLen))
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        let selected = selectedRange()
        let ns = (textStorage?.string ?? "") as NSString
        guard selected.location <= ns.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = ns.paragraphRange(for: selected)
        let line = ns.substring(with: lineRange)

        if line.hasPrefix("☐ ") || line.hasPrefix("☑ ") {
            let content = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                // Empty checklist item: pressing Return exits checklist mode!
                let replaceRange = NSRange(location: lineRange.location, length: min(2, lineRange.length))
                if shouldChangeText(in: replaceRange, replacementString: "") {
                    textStorage?.replaceCharacters(in: replaceRange, with: "")
                    didChangeText()
                    setSelectedRange(NSRange(location: lineRange.location, length: 0))
                }
                return
            } else {
                // Continue checklist on new line
                super.insertNewline(sender)
                super.insertText("☐ ", replacementRange: selectedRange())
                return
            }
        }

        super.insertNewline(sender)
    }

    private func resizeImage(at index: Int, corner: Int, from start: NSPoint) {
        guard let cell = imageCell(at: index) else { return }
        let original = cell.displaySize
        let aspect = original.width / max(original.height, 1)
        // Right-hand handles grow the image when dragged right, left-hand ones when dragged left.
        let direction: CGFloat = corner % 2 == 1 ? 1 : -1
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(event.locationInWindow, from: nil)
            let width = min(max(24, original.width + direction * (point.x - start.x)), maxImageWidth).rounded()
            cell.displaySize = NSSize(width: width, height: (width / aspect).rounded())
            resizeLabel = "\(Int(cell.displaySize.width)) × \(Int(cell.displaySize.height))"
            relayoutImage(at: index)
            if event.type == .leftMouseUp { break }
        }
        resizeLabel = nil
        let final = cell.displaySize
        cell.displaySize = original
        setImageSize(at: index, to: final)
    }

    /// Undoable resize; `size` is clamped to the page width.
    func setImageSize(at index: Int, to size: NSSize) {
        guard let cell = imageCell(at: index) else { return }
        let old = cell.displaySize
        let fitted = RichTextIO.fit(size, maxWidth: maxImageWidth)
        guard fitted != old else { return relayoutImage(at: index) }
        cell.displaySize = fitted
        undoManager?.registerUndo(withTarget: self) { $0.setImageSize(at: index, to: old) }
        undoManager?.setActionName("Resize Image")
        relayoutImage(at: index)
        didChangeText()
    }

    private func relayoutImage(at index: Int) {
        let range = NSRange(location: index, length: 1)
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: range)
        needsDisplay = true
        refreshImageOutline()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = imageIndex(at: point) else { return super.menu(for: event) }
        setSelectedRange(NSRange(location: index, length: 1))
        return imageMenu(for: index)
    }

    func imageMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        guard let cell = imageCell(at: index) else { return menu }
        let natural = cell.naturalSize
        let sizes: [(String, NSSize)] = [
            ("Small", NSSize(width: 160, height: 160 * natural.height / max(natural.width, 1))),
            ("Medium", NSSize(width: 320, height: 320 * natural.height / max(natural.width, 1))),
            ("Large", NSSize(width: 520, height: 520 * natural.height / max(natural.width, 1))),
            ("Fit Width", NSSize(width: maxImageWidth, height: maxImageWidth * natural.height / max(natural.width, 1))),
            ("Original Size", natural),
        ]
        for (title, size) in sizes {
            let item = ClosureMenuItem(title: title) { [weak self] in self?.setImageSize(at: index, to: size) }
            item.state = abs(cell.displaySize.width - RichTextIO.fit(size, maxWidth: maxImageWidth).width) < 1 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(delete(_:)), keyEquivalent: ""))
        return menu
    }
}

/// The page for rich text scratches: a formatting bar over a centred, document-like text column.
final class RichTextViewController: NSViewController, NSTextViewDelegate, NSTextStorageDelegate {
    /// Called (on every edit) with a snapshot of the document to save.
    var onChange: ((NSAttributedString) -> Void)?
    private(set) var scratch: Scratch?

    private let storage = NSTextStorage()
    private var textView: RichTextView!
    private let scroll = NSScrollView()
    private let bar = NSStackView()
    private let styleButton = ToolbarMenuButton(compact: true)
    private let sizeButton = ToolbarMenuButton(compact: true)
    private var toggles: [String: HoverButton] = [:]
    private var alignButtons: [HoverButton] = []
    private let imageButton = ToolbarMenuButton(compact: true)
    private let countLabel = NSTextField.label("", size: 11)
    private var pendingImageRange: NSRange?
    private var countTimer: Timer?
    /// Keeps the text in a readable column on wide windows.
    private static let columnWidth: CGFloat = 760

    private struct Style {
        let title: String
        let size: CGFloat
        let weight: NSFont.Weight
        var monospaced = false
        var spacingBefore: CGFloat = 0
    }

    private static let styles = [
        Style(title: "Title", size: 28, weight: .bold, spacingBefore: 8),
        Style(title: "Heading", size: 22, weight: .bold, spacingBefore: 6),
        Style(title: "Subheading", size: 18, weight: .semibold, spacingBefore: 4),
        Style(title: "Body", size: RichTextIO.bodySize, weight: .regular),
        Style(title: "Monospaced", size: 14, weight: .regular, monospaced: true),
    ]
    private static let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]

    override func loadView() {
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.delegate = self

        textView = RichTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = true
        textView.usesRuler = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 48, height: 48)
        textView.typingAttributes = RichTextIO.defaultAttributes
        textView.onConvertToBullet = { [weak self] in
            self?.toggleList(.disc)
        }

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = RichTextView.canvasColor
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 3

        buildBar()
        let divider = NSBox()
        divider.boxType = .separator
        let root = NSStackView(views: [bar, divider, scroll])
        root.orientation = .vertical
        root.spacing = 0
        for v in root.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let pw = min(RichTextView.columnWidth, max(300, scroll.contentSize.width - 48))
        let px = max(24, ((scroll.contentSize.width - pw) / 2).rounded())
        let insetX = px + RichTextView.pagePaddingX
        let insetY: CGFloat = 20 + RichTextView.pagePaddingY
        if abs(textView.textContainerInset.width - insetX) > 0.5 || abs(textView.textContainerInset.height - insetY) > 0.5 {
            textView.textContainerInset = NSSize(width: insetX, height: insetY)
            textView.needsDisplay = true
        }
    }

    // MARK: Formatting bar

    private func button(_ id: String, _ symbol: String, _ tip: String, toggle: Bool = false) -> HoverButton {
        let b = ToolbarStyle.makeCompact(ToolbarStyle.button(symbol: symbol, tip: tip, target: self,
                                                             action: #selector(barButtonClicked(_:))))
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.isToggle = toggle
        toggles[id] = b
        return b
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = NSColor.labelColor.withAlphaComponent(0.12)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    private func buildBar() {
        styleButton.onClick = { [weak self] b in self?.showStyleMenu(from: b) }
        styleButton.toolTip = "Paragraph style"
        sizeButton.onClick = { [weak self] b in self?.showSizeMenu(from: b) }
        sizeButton.toolTip = "Font size"
        imageButton.onClick = { [weak self] b in self?.showImageMenu(from: b) }
        imageButton.toolTip = "Insert or resize images (paste or drop images to add them)"
        imageButton.show(symbol: "photo", tint: .secondaryLabelColor, title: "Image", accessibility: "Image")

        let textColor = button("textColor", "paintpalette", "Text colour")
        let highlight = button("highlight", "highlighter", "Highlight")
        alignButtons = [("alignLeft", "text.alignleft", "Align left"), ("alignCenter", "text.aligncenter", "Centre"),
                        ("alignRight", "text.alignright", "Align right"), ("alignJustified", "text.justify", "Justify")]
            .map { button($0.0, $0.1, $0.2, toggle: true) }

        let views: [NSView] = [
            styleButton, sizeButton, separator(),
            ToolbarGroup([button("bold", "bold", "Bold (⌘B)", toggle: true), button("italic", "italic", "Italic (⌘I)", toggle: true),
                          button("underline", "underline", "Underline (⌘U)", toggle: true),
                          button("strikethrough", "strikethrough", "Strikethrough", toggle: true)], compact: true),
            ToolbarGroup([textColor, highlight], compact: true), separator(),
            ToolbarGroup(alignButtons, compact: true), separator(),
            ToolbarGroup([button("bulletList", "list.bullet", "Bulleted list"),
                          button("numberedList", "list.number", "Numbered list")], compact: true), separator(),
            imageButton,
            ToolbarGroup([button("fonts", "textformat", "Show Fonts (⌘T)"),
                          button("clearFormatting", "eraser", "Clear formatting")], compact: true),
        ]
        views.forEach(bar.addArrangedSubview)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(countLabel)
        countLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        bar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        for v in bar.arrangedSubviews { v.setContentCompressionResistancePriority(.init(200), for: .horizontal) }
        bar.setVisibilityPriority(.detachOnlyIfNecessary, for: countLabel)
    }

    /// Runs a formatting command from the Format menu or a shortcut ("bold", "alignCenter", "bigger"…).
    func run(_ command: String) {
        view.window?.makeFirstResponder(textView)
        switch command {
        case "bigger": stepFontSize(1)
        case "smaller": stepFontSize(-1)
        case "insertImage": chooseImage()
        default: apply(command, from: nil)
        }
        updateBar()
    }

    @objc private func barButtonClicked(_ sender: HoverButton) {
        guard let id = sender.identifier?.rawValue else { return }
        view.window?.makeFirstResponder(textView)
        apply(id, from: sender)
        updateBar()
    }

    private func apply(_ id: String, from sender: NSView?) {
        switch id {
        case "bold": toggleTrait(.boldFontMask)
        case "italic": toggleTrait(.italicFontMask)
        case "underline": toggleLine(.underlineStyle)
        case "strikethrough": toggleLine(.strikethroughStyle)
        case "alignLeft": textView.alignLeft(nil)
        case "alignCenter": textView.alignCenter(nil)
        case "alignRight": textView.alignRight(nil)
        case "alignJustified": textView.alignJustified(nil)
        case "bulletList": toggleList(NSTextList.MarkerFormat.disc)
        case "numberedList": toggleList(NSTextList.MarkerFormat.decimal)
        case "textColor": if let sender { showColorMenu(from: sender, highlight: false) }
        case "highlight": if let sender { showColorMenu(from: sender, highlight: true) }
        case "fonts": NSFontManager.shared.orderFrontFontPanel(nil)
        case "clearFormatting": clearFormatting()
        default: break
        }
    }

    private func popUp(_ menu: NSMenu, from view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func showStyleMenu(from view: NSView) {
        let menu = NSMenu()
        for style in Self.styles {
            let item = ClosureMenuItem(title: style.title) { [weak self] in self?.applyStyle(style) }
            item.attributedTitle = NSAttributedString(string: style.title, attributes: [.font: font(for: style, size: min(style.size, 20))])
            menu.addItem(item)
        }
        popUp(menu, from: view)
    }

    private func showSizeMenu(from view: NSView) {
        let menu = NSMenu()
        let current = currentFont.pointSize
        for size in Self.fontSizes {
            let item = ClosureMenuItem(title: "\(Int(size)) pt") { [weak self] in
                self?.changeFonts { NSFontManager.shared.convert($0, toSize: size) }
            }
            item.state = abs(current - size) < 0.5 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Bigger") { [weak self] in self?.stepFontSize(1) })
        menu.addItem(ClosureMenuItem(title: "Smaller") { [weak self] in self?.stepFontSize(-1) })
        popUp(menu, from: view)
    }

    private func showColorMenu(from view: NSView, highlight: Bool) {
        let menu = NSMenu()
        let colors: [(String, NSColor?)] = highlight
            ? [("None", nil), ("Yellow", .systemYellow.withAlphaComponent(0.45)), ("Green", .systemGreen.withAlphaComponent(0.35)),
               ("Blue", .systemBlue.withAlphaComponent(0.3)), ("Pink", .systemPink.withAlphaComponent(0.3)),
               ("Orange", .systemOrange.withAlphaComponent(0.35))]
            : [("Default", nil), ("Red", .systemRed), ("Orange", .systemOrange), ("Green", .systemGreen),
               ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray)]
        for (title, color) in colors {
            let item = ClosureMenuItem(title: title) { [weak self] in self?.setColor(color, highlight: highlight) }
            item.image = swatch(color)
            menu.addItem(item)
        }
        if !highlight {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "More Colours…") { NSColorPanel.shared.orderFront(nil) })
        }
        popUp(menu, from: view)
    }

    private func swatch(_ color: NSColor?) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            (color ?? .textColor).setFill()
            if color == nil { NSColor.clear.setFill() }
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            path.stroke()
            return true
        }
    }

    private func showImageMenu(from view: NSView) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Insert Image…") { [weak self] in self?.chooseImage() })
        if let index = textView.selectedImageIndex {
            menu.addItem(.separator())
            for item in textView.imageMenu(for: index).items.prefix(5) {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        } else {
            let hint = NSMenuItem(title: "Click an image to resize it", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        popUp(menu, from: view)
    }

    // MARK: Loading

    func load(_ scratch: Scratch, text: NSAttributedString) {
        _ = view
        self.scratch = scratch
        storage.setAttributedString(text)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.typingAttributes = text.length > 0
            ? storage.attributes(at: 0, effectiveRange: nil).filter { $0.key != .attachment }
            : RichTextIO.defaultAttributes
        scroll.magnification = 1
        textView.scroll(.zero)
        updateBar()
        updateCount()
    }

    /// The same document, after a rename or move.
    func retarget(_ scratch: Scratch) {
        self.scratch = scratch
    }

    var document: NSAttributedString { NSAttributedString(attributedString: storage) }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func performFind(_ action: NSTextFinder.Action) {
        focus()
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    /// Selects and scrolls to a range of the document's plain text (from Find in Files).
    func reveal(_ range: NSRange) {
        guard NSMaxRange(range) <= textView.string.utf16.count else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    func zoom(_ delta: CGFloat?) {
        scroll.magnification = delta.map { min(max(scroll.magnification + $0, 0.5), 3) } ?? 1
    }

    // MARK: Editing

    func textDidChange(_ notification: Notification) {
        onChange?(document)
        scheduleCount()
        textView.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateBar()
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0 else { return }
        let hasAttachment = textStorage.string.utf16.dropFirst(editedRange.location).prefix(editedRange.length)
            .contains(0xFFFC)
        guard hasAttachment else { return }
        pendingImageRange = pendingImageRange.map { NSUnionRange($0, editedRange) } ?? editedRange
        DispatchQueue.main.async { [weak self] in self?.adoptNewImages() }
    }

    /// Pasted and dropped images arrive as plain attachments (often huge TIFFs); store them as PNG/JPEG
    /// with a resizable cell, scaled down to the page width.
    private func adoptNewImages() {
        guard let range = pendingImageRange else { return }
        pendingImageRange = nil
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        var replacements: [(NSRange, NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: clamped) { value, r, _ in
            guard let attachment = value as? NSTextAttachment, !(attachment.attachmentCell is ImageAttachmentCell),
                  let image = RichTextIO.image(of: attachment) else { return }
            replacements.append((r, RichTextIO.attachment(for: image, data: attachment.fileWrapper?.regularFileContents,
                                                          maxWidth: textView.maxImageWidth)))
        }
        guard !replacements.isEmpty else { return }
        storage.beginEditing()
        for (r, attachment) in replacements { storage.addAttribute(.attachment, value: attachment, range: r) }
        storage.endEditing()
        onChange?(document)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let inserted = NSMutableAttributedString()
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { continue }
                let attachment = RichTextIO.attachment(for: image, data: data, maxWidth: self.textView.maxImageWidth)
                inserted.append(NSAttributedString(attachment: attachment))
            }
            guard inserted.length > 0 else { return }
            self.focus()
            self.textView.insertText(inserted, replacementRange: self.textView.selectedRange())
        }
    }

    /// Applies `transform` to every font in the selection, or to the typing attributes at a caret.
    private func changeFonts(_ transform: (NSFont) -> NSFont) {
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            let font = textView.typingAttributes[.font] as? NSFont ?? currentFont
            textView.typingAttributes[.font] = transform(font)
            updateBar()
            return
        }
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: transform(value as? NSFont ?? currentFont), range: r)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        updateBar()
    }

    private func setAttribute(_ key: NSAttributedString.Key, _ value: Any?) {
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            textView.typingAttributes[key] = value
            updateBar()
            return
        }
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
        }
        storage.endEditing()
        textView.didChangeText()
        updateBar()
    }

    /// The attributes at the caret (typing attributes) or at the start of the selection.
    private var currentAttributes: [NSAttributedString.Key: Any] {
        let range = textView.selectedRange()
        if range.length == 0 || range.location >= storage.length { return textView.typingAttributes }
        return storage.attributes(at: range.location, effectiveRange: nil)
    }

    private var currentFont: NSFont {
        currentAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: RichTextIO.bodySize)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let has = NSFontManager.shared.traits(of: currentFont).contains(trait)
        changeFonts { has ? NSFontManager.shared.convert($0, toNotHaveTrait: trait) : NSFontManager.shared.convert($0, toHaveTrait: trait) }
    }

    private func toggleLine(_ key: NSAttributedString.Key) {
        let on = (currentAttributes[key] as? Int ?? 0) != 0
        setAttribute(key, on ? nil : NSUnderlineStyle.single.rawValue)
    }

    private func stepFontSize(_ direction: Int) {
        changeFonts { font in
            let sizes = Self.fontSizes
            let next = direction > 0 ? sizes.first { $0 > font.pointSize + 0.5 } ?? font.pointSize + 8
                                     : sizes.last { $0 < font.pointSize - 0.5 } ?? max(6, font.pointSize - 1)
            return NSFontManager.shared.convert(font, toSize: next)
        }
    }

    private func setColor(_ color: NSColor?, highlight: Bool) {
        if highlight {
            setAttribute(.backgroundColor, color)
        } else {
            setAttribute(.foregroundColor, color ?? NSColor.black)
        }
    }

    private func font(for style: Style, size: CGFloat? = nil) -> NSFont {
        style.monospaced ? .monospacedSystemFont(ofSize: size ?? style.size, weight: style.weight)
            : .systemFont(ofSize: size ?? style.size, weight: style.weight)
    }

    /// Paragraph styles change whole paragraphs, like the style menu in Pages or Notes.
    private func applyStyle(_ style: Style) {
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: textView.selectedRange())
        let font = font(for: style)
        if paragraphs.length == 0 {
            textView.typingAttributes[.font] = font
            updateBar()
            return
        }
        guard textView.shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: paragraphs) { value, r, _ in
            var applied = font
            // Keep italics inside the paragraph; bold comes from the style itself.
            if let old = value as? NSFont, NSFontManager.shared.traits(of: old).contains(.italicFontMask) {
                applied = NSFontManager.shared.convert(applied, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: applied, range: r)
        }
        storage.enumerateAttribute(.paragraphStyle, in: paragraphs) { value, r, _ in
            let paragraph = (value as? NSParagraphStyle ?? RichTextIO.defaultParagraph).mutableCopy() as! NSMutableParagraphStyle
            paragraph.paragraphSpacingBefore = style.spacingBefore
            storage.addAttribute(.paragraphStyle, value: paragraph, range: r)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.typingAttributes[.font] = font
        updateBar()
    }

    private func clearFormatting() {
        let range = textView.selectedRange()
        guard range.length > 0 else {
            textView.typingAttributes = RichTextIO.defaultAttributes
            return updateBar()
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, r, _ in
            var cleared = RichTextIO.defaultAttributes
            if let attachment = attributes[.attachment] { cleared[.attachment] = attachment }
            if let link = attributes[.link] { cleared[.link] = link }
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle, !paragraph.textLists.isEmpty {
                cleared[.paragraphStyle] = paragraph
            }
            storage.setAttributes(cleared, range: r)
        }
        storage.endEditing()
        textView.didChangeText()
        updateBar()
    }

    /// Adds or removes a list on the selected paragraphs. NSTextView continues the list on Return.
    private func toggleList(_ format: NSTextList.MarkerFormat) {
        let ns = storage.string as NSString
        let whole = ns.paragraphRange(for: textView.selectedRange())
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            paragraphs.append(enclosing)
        }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: whole.location, length: 0)] }
        let lists = paragraphs.map { r -> NSTextList? in
            guard r.location < storage.length else { return nil }
            return (storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last
        }
        let removing = lists.allSatisfy { $0?.markerFormat == format }
        let list = NSTextList(markerFormat: format, options: 0)
        let result = NSMutableAttributedString()
        for (n, r) in paragraphs.enumerated() {
            let paragraphText = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: r))
            // Drop an existing "\t•\t" style marker before re-marking or un-listing.
            if lists[n] != nil, let marker = paragraphText.string.range(of: #"^\t[^\t\n]*\t"#, options: .regularExpression) {
                paragraphText.deleteCharacters(in: NSRange(marker, in: paragraphText.string))
            }
            let base = (paragraphText.length > 0 ? paragraphText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)
                ?? (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? RichTextIO.defaultParagraph
            let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
            if removing {
                paragraph.textLists = []
                paragraph.headIndent = 0
                paragraph.firstLineHeadIndent = 0
                paragraph.tabStops = NSParagraphStyle.default.tabStops
            } else {
                paragraph.textLists = [list]
                paragraph.headIndent = 30
                paragraph.firstLineHeadIndent = 0
                paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 20), NSTextTab(textAlignment: .left, location: 30)]
                var attributes = paragraphText.length > 0 ? paragraphText.attributes(at: 0, effectiveRange: nil) : textView.typingAttributes
                attributes.removeValue(forKey: .attachment)
                paragraphText.insert(NSAttributedString(string: "\t\(list.marker(forItemNumber: n + 1))\t", attributes: attributes), at: 0)
            }
            paragraphText.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: paragraphText.length))
            result.append(paragraphText)
        }
        let target = NSRange(location: paragraphs.first!.location, length: NSMaxRange(paragraphs.last!) - paragraphs.first!.location)
        guard textView.shouldChangeText(in: target, replacementString: result.string) else { return }
        storage.replaceCharacters(in: target, with: result)
        textView.didChangeText()
        let end = target.location + result.length
        let caret = result.string.hasSuffix("\n") ? end - 1 : end
        textView.setSelectedRange(NSRange(location: max(target.location, caret), length: 0))
        if result.length == 0 || paragraphs.count == 1 && result.string.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1 {
            var typing = textView.typingAttributes
            typing[.paragraphStyle] = result.length > 0 ? result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) : nil
            textView.typingAttributes = typing
        }
    }

    // MARK: Bar state

    private func updateBar() {
        let attributes = currentAttributes
        let font = currentFont
        let traits = NSFontManager.shared.traits(of: font)
        toggles["bold"]?.state = traits.contains(.boldFontMask) ? .on : .off
        toggles["italic"]?.state = traits.contains(.italicFontMask) ? .on : .off
        toggles["underline"]?.state = (attributes[.underlineStyle] as? Int ?? 0) != 0 ? .on : .off
        toggles["strikethrough"]?.state = (attributes[.strikethroughStyle] as? Int ?? 0) != 0 ? .on : .off
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        let alignment = paragraph?.alignment ?? .natural
        let index: Int
        switch alignment {
        case .center: index = 1
        case .right: index = 2
        case .justified: index = 3
        default: index = 0
        }
        for (i, b) in alignButtons.enumerated() { b.state = i == index ? .on : .off }
        let format = paragraph?.textLists.last?.markerFormat
        toggles["bulletList"]?.state = format == .disc ? .on : .off
        toggles["numberedList"]?.state = format == .decimal ? .on : .off

        let isMono = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        let style = Self.styles.first { s in
            abs(s.size - font.pointSize) < 0.5 && s.monospaced == isMono
        }
        styleButton.show(symbol: "paragraphsign", tint: .secondaryLabelColor, title: style?.title ?? "Custom",
                         accessibility: "Paragraph style")
        sizeButton.show(symbol: "textformat.size", tint: .secondaryLabelColor, title: "\(Int(font.pointSize.rounded()))",
                        accessibility: "Font size")
        imageButton.show(symbol: "photo", tint: textView.selectedImageIndex != nil ? .controlAccentColor : .secondaryLabelColor,
                         title: textView.selectedImageIndex != nil ? "Image Size" : "Image", accessibility: "Image")
    }

    private func scheduleCount() {
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.updateCount() }
    }

    private func updateCount() {
        var words = 0
        let string = storage.string
        string.enumerateSubstrings(in: string.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        countLabel.stringValue = words == 1 ? "1 word" : "\(words) words"
    }
}

// MARK: Go to Symbol

extension RichTextViewController {
    /// Headings: short paragraphs set larger than body text (Title > Heading > Subheading), or entirely bold.
    func symbols() -> [DocumentSymbol] {
        _ = view
        let text = storage.string as NSString
        let body = RichTextIO.bodySize
        var headings: [(name: String, range: NSRange, level: Int)] = []
        var line = 1
        var lineCursor = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs]) { para, range, _, stop in
            guard let para else { return }
            let trimmed = para.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, range.length <= 200,
                  let font = self.storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let size = font.pointSize
            var bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            if bold {
                // Bold only counts when the whole paragraph is bold, not a word at its start.
                self.storage.enumerateAttribute(.font, in: range) { value, _, inner in
                    if let f = value as? NSFont, !f.fontDescriptor.symbolicTraits.contains(.bold) {
                        bold = false
                        inner.pointee = true
                    }
                }
            }
            let level = size >= 26 ? 1 : size >= 20 ? 2 : size > body + 1 ? 3 : bold && range.length <= 80 ? 4 : 0
            guard level > 0 else { return }
            headings.append((trimmed, range, level))
            if headings.count >= 5000 { stop.pointee = true }
        }
        var symbols: [DocumentSymbol] = []
        var open: [(level: Int, name: String)] = []
        for (index, heading) in headings.enumerated() {
            while let last = open.last, last.level >= heading.level { open.removeLast() }
            line += text.substring(with: NSRange(location: lineCursor, length: heading.range.location - lineCursor))
                .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            lineCursor = heading.range.location
            let end = headings[(index + 1)...].first { $0.level <= heading.level }?.range.location ?? text.length
            symbols.append(DocumentSymbol(name: heading.name, kind: "heading", range: heading.range, end: end,
                                          depth: open.count, line: line, container: open.last?.name ?? ""))
            open.append((heading.level, heading.name))
        }
        return symbols
    }

    var cursorLocation: Int { textView?.selectedRange().location ?? 0 }

    func peek(_ range: NSRange) {
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }
}
