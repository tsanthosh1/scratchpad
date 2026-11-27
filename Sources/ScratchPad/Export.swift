import AppKit
import UniformTypeIdentifiers
import WebKit

/// Renderers for OpenAPI specs, shown in the preview and used for exports.
enum SpecViewer: String, CaseIterable {
    case swagger, scalar, kong

    var title: String {
        switch self {
        case .swagger: return "Swagger UI"
        case .scalar: return "Scalar"
        case .kong: return "Kong"
        }
    }

    var symbol: String {
        switch self {
        case .swagger: return "curlybraces.square"
        case .scalar: return "book.pages"
        case .kong: return "rectangle.split.3x1"
        }
    }

    var actionId: String { "specViewer" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Files under the bundle's `web` folder that the viewer needs, scripts first.
    fileprivate var scripts: [String] {
        switch self {
        case .swagger: return ["swagger-ui-bundle.js"]
        case .scalar: return ["scalar.js"]
        case .kong: return ["kong-spec-renderer.js"]
        }
    }

    fileprivate var styles: [String] {
        switch self {
        case .swagger: return ["swagger-ui.css"]
        case .scalar: return []
        case .kong: return ["kong-spec-renderer.css"]
        }
    }
}

enum ExportFormat: String {
    case pdf, html, mhtml

    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .html: return .html
        case .mhtml: return UTType(filenameExtension: "mhtml") ?? .data
        }
    }
}

// MARK: - Standalone OpenAPI pages

enum SpecPage {
    static var webDir = Bundle.main.resourceURL?.appendingPathComponent("web")

    /// A single self-contained page: the viewer library, its styles and the spec are all inlined, so it works offline.
    /// `snapshot` expands everything, for a static copy taken from it.
    static func html(viewer: SpecViewer, spec: String, title: String, snapshot: Bool) -> String? {
        guard let dir = webDir else { return nil }
        func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        var styles = viewer.styles.compactMap(read)
        guard styles.count == viewer.styles.count, let base = read("viewer.css"), let runtime = read("viewer.js") else { return nil }
        styles.append(base)
        var scripts = viewer.scripts.compactMap(read)
        guard scripts.count == viewer.scripts.count else { return nil }
        scripts.append(runtime)
        let options: [String: Any] = ["viewer": viewer.rawValue, "spec": spec, "standalone": true, "snapshot": snapshot]
        guard let data = try? JSONSerialization.data(withJSONObject: options), var json = String(data: data, encoding: .utf8) else {
            return nil
        }
        json = json.replacingOccurrences(of: "<", with: "\\u003c")
        let styleTags = styles.map { "<style>\($0.replacingOccurrences(of: "</style", with: "<\\/style"))</style>" }.joined(separator: "\n")
        let scriptTags = scripts.map { "<script>\(scriptSafe($0))</script>" }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="ScratchPad (\(viewer.title))">
        <title>\(escape(title))</title>
        \(styleTags)
        </head>
        <body>
        <div id="viewer"></div>
        \(scriptTags)
        <script type="application/json" id="spec-options">\(json)</script>
        <script>SpecViewer.render(JSON.parse(document.getElementById('spec-options').textContent));</script>
        </body>
        </html>
        """
    }

    /// Script text that can't end its `<script>` element early: "<!--" would let a later "<script" in a string hide our
    /// closing tag. `\x3C` reads the same in strings, templates and regexes (also /u ones, unlike `\<`).
    private static func scriptSafe(_ js: String) -> String {
        js.replacingOccurrences(of: "</script", with: "\\x3C/script", options: .caseInsensitive)
            .replacingOccurrences(of: "<!--", with: "\\x3C!--")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Static snapshots

/// Renders a page in an offscreen web view and returns its DOM as static markup (scripts removed), for MHTML.
final class PageSnapshot: NSObject, WKNavigationDelegate {
    private static var running: Set<PageSnapshot> = []
    private let webView: WKWebView
    /// Pages without a window count as hidden and get their timers throttled, so viewers that render in steps
    /// (Swagger UI expanding operations) would be caught half done. This one is transparent and ignores the mouse.
    private let host: NSWindow
    private let completion: (String?) -> Void
    private let file: URL

    private init(completion: @escaping (String?) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("ScratchPad-export-\(UUID().uuidString).html")
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
        webView = WKWebView(frame: frame, configuration: config)
        host = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.alphaValue = 0
        host.ignoresMouseEvents = true
        host.hasShadow = false
        host.level = .init(Int(CGWindowLevelForKey(.desktopWindow)))
        host.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        host.contentView = webView
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
        host.orderBack(nil)
    }

    /// `html` must define `SpecViewer.snapshot()` (see viewer.js).
    static func capture(html: String, completion: @escaping (String?) -> Void) {
        let snapshot = PageSnapshot(completion: completion)
        running.insert(snapshot)
        // Loaded from a file, not a string: an opaque about:blank origin has no storage, and Scalar fails to start there.
        do {
            try Data(html.utf8).write(to: snapshot.file)
            snapshot.webView.loadFileURL(snapshot.file, allowingReadAccessTo: snapshot.file)
        } catch {
            snapshot.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript("return await SpecViewer.snapshot()", arguments: [:], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { NSLog("ScratchPad: snapshot failed: \(error)") }
            self?.finish((try? result.get()) as? String)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ html: String?) {
        guard Self.running.remove(self) != nil else { return }
        host.orderOut(nil)
        host.contentView = nil
        try? FileManager.default.removeItem(at: file)
        completion(html)
    }
}

// MARK: - MHTML

/// MIME HTML (RFC 2557): the page plus the images it links, in one file that Chrome, Edge and Word open.
enum MHTML {
    /// Downloads the page's http(s) images (best effort) and packs everything together.
    static func make(html: String, title: String, completion: @escaping (Data) -> Void) {
        let urls = imageURLs(in: html)
        guard !urls.isEmpty else { return completion(encode(html: html, title: title, resources: [])) }
        let group = DispatchGroup()
        let lock = NSLock()
        var resources: [(URL, String, Data)] = []
        let session = URLSession(configuration: .ephemeral)
        for url in urls {
            group.enter()
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            session.dataTask(with: request) { data, response, _ in
                defer { group.leave() }
                guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                let mime = http.mimeType ?? "application/octet-stream"
                lock.lock()
                resources.append((url, mime, data))
                lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            session.finishTasksAndInvalidate()
            completion(encode(html: html, title: title, resources: resources))
        }
    }

    private static func imageURLs(in html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*["'](https?://[^"']+)["']"#, options: .caseInsensitive) else {
            return []
        }
        let ns = html as NSString
        var seen = Set<String>()
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard seen.insert(raw).inserted, seen.count <= 100 else { return nil }
            return URL(string: raw)
        }
    }

    static func encode(html: String, title: String, resources: [(url: URL, mime: String, data: Data)]) -> Data {
        let boundary = "----=_ScratchPad_\(UUID().uuidString)"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let location = "file:///\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "page").html"
        var out = [
            "From: <Saved by ScratchPad>",
            "Snapshot-Content-Location: \(location)",
            "Subject: \(encodedHeader(title))",
            "Date: \(date.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: multipart/related;",
            "\ttype=\"text/html\";",
            "\tboundary=\"\(boundary)\"",
            "", "",
        ].joined(separator: "\r\n")
        func part(_ type: String, location: String, data: Data) {
            out += "--\(boundary)\r\nContent-Type: \(type)\r\nContent-Transfer-Encoding: base64\r\nContent-Location: \(location)\r\n\r\n"
            out += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            out += "\r\n\r\n"
        }
        part("text/html; charset=utf-8", location: location, data: Data(html.utf8))
        for resource in resources { part(resource.mime, location: resource.url.absoluteString, data: resource.data) }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    /// RFC 2047 for non-ASCII titles.
    private static func encodedHeader(_ text: String) -> String {
        text.allSatisfy(\.isASCII) ? text : "=?utf-8?B?\(Data(text.utf8).base64EncodedString())?="
    }
}

// MARK: - Export popover

/// The Export button's popover: a format list, plus the viewer for OpenAPI specs.
final class ExportPopoverController: NSViewController {
    struct Option {
        let format: ExportFormat
        let title: String
        let detail: String
        let symbol: String
    }

    private let heading: String
    private let options: [Option]
    private let viewers: [SpecViewer]
    private var viewer: SpecViewer
    private let onExport: (ExportFormat, SpecViewer?) -> Void
    private let segmented = NSSegmentedControl()

    init(heading: String, options: [Option], viewers: [SpecViewer], viewer: SpecViewer,
         onExport: @escaping (ExportFormat, SpecViewer?) -> Void) {
        self.heading = heading
        self.options = options
        self.viewers = viewers
        self.viewer = viewer
        self.onExport = onExport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        var rows: [NSView] = [title]
        if !viewers.isEmpty {
            segmented.segmentCount = viewers.count
            for (i, v) in viewers.enumerated() {
                segmented.setLabel(v.title, forSegment: i)
                segmented.setWidth(0, forSegment: i)
            }
            segmented.selectedSegment = viewers.firstIndex(of: viewer) ?? 0
            segmented.segmentDistribution = .fillEqually
            segmented.target = self
            segmented.action = #selector(viewerChanged)
            rows.append(segmented)
        }
        for (i, option) in options.enumerated() {
            let row = ExportOptionRow(option: option)
            row.tag = i
            row.target = self
            row.action = #selector(optionClicked(_:))
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: title)
        if !viewers.isEmpty { stack.setCustomSpacing(10, after: segmented) }
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
        for row in rows.dropFirst() {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view = stack
    }

    @objc private func viewerChanged() {
        if viewers.indices.contains(segmented.selectedSegment) { viewer = viewers[segmented.selectedSegment] }
    }

    @objc private func optionClicked(_ sender: ExportOptionRow) {
        onExport(options[sender.tag].format, viewers.isEmpty ? nil : viewer)
    }
}

/// A clickable row: tinted icon, title and a one-line explanation, highlighted on hover.
private final class ExportOptionRow: NSControl {
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var pressed = false { didSet { if pressed != oldValue { refresh() } } }
    private let icon = NSImageView()
    private let title: NSTextField
    private let detail: NSTextField

    init(option: ExportPopoverController.Option) {
        title = NSTextField(labelWithString: option.title)
        detail = NSTextField(wrappingLabelWithString: option.detail)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        icon.image = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        for label in [title, detail] {
            label.isSelectable = false
            label.isEditable = false
        }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let stack = NSStackView(views: [icon, text])
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Export as \(option.title)")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// The whole row is one target: labels must not take clicks or show a text cursor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { sendAction(action, to: target) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let highlighted = hovering || pressed
        icon.contentTintColor = highlighted ? .white : .controlAccentColor
        title.textColor = highlighted ? .white : .labelColor
        detail.textColor = highlighted ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            let fill = pressed ? accent.blended(withFraction: 0.2, of: .black) : hovering ? accent : nil
            layer?.backgroundColor = fill?.cgColor
        }
    }
}
