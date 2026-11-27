import AppKit
import WebKit

struct EditorStatus {
    var line = 1
    var column = 1
    var cursors = 1
    var selected = 0
    var length = 0
}

protocol EditorControllerDelegate: AnyObject {
    func editorDidBecomeReady(_ editor: EditorController)
    func editor(_ editor: EditorController, didChange id: String, text: String)
    func editor(_ editor: EditorController, status: EditorStatus)
    func editor(_ editor: EditorController, didPasteIntoEmpty id: String)
    func editor(_ editor: EditorController, requestsAction id: String)
    func editor(_ editor: EditorController, previewModeDidChange mode: PreviewMode)
    func editorDidCloseDiff(_ editor: EditorController)
    func editor(_ editor: EditorController, didPasteCurl text: String, separatorBefore: Bool, separatorAfter: Bool)
    func editor(_ editor: EditorController, runRequestAt offset: Int)
    func editor(_ editor: EditorController, openResponse text: String, language: Language)
    func editor(_ editor: EditorController, showMessage text: String)
}

enum PreviewMode: String {
    case off, split, full
}

/// A slice of the document handed to native text transforms. Offsets are UTF-16.
struct TextSelection {
    let from: Int
    let to: Int
    let text: String
}

/// Hosts the CodeMirror editor and exposes it through a small typed API.
final class EditorController: NSObject {
    weak var delegate: EditorControllerDelegate?
    let webView: WKWebView
    private(set) var isReady = false
    /// Whether the open document has a preview: Markdown, HTML, CSV/TSV, or YAML/JSON holding an OpenAPI spec.
    private(set) var previewAvailable = false
    /// What the preview shows ("markdown", "openapi", "html", "csv"…), nil when there's none.
    private(set) var previewKind: String?
    private var queued: [(script: String, arguments: [String: Any])] = []

    override init() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        config.userContentController = content
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let editorWebView = EditorWebView(frame: .zero, configuration: config)
        webView = editorWebView
        super.init()
        editorWebView.onCommand = { [weak self] in self?.exec($0) }
        content.add(WeakMessageHandler(self), name: "bridge")
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("web"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
            NSLog("ScratchPad: web resources missing from the app bundle")
            return
        }
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    // MARK: API

    func load(id: String, text: String, language: Language) {
        // Passed as arguments rather than spliced into the script, so large documents aren't re-parsed as JS source.
        call("ScratchEditor.load(id, text, language)", arguments: ["id": id, "text": text, "language": language.rawValue])
    }

    func forget(id: String) {
        call("ScratchEditor.forget(\(js(id)))")
    }

    func rename(from oldId: String, to newId: String) {
        call("ScratchEditor.rename(\(js(oldId)), \(js(newId)))")
    }

    func setLanguage(_ language: Language) {
        call("ScratchEditor.setLanguage(\(js(language.rawValue)))")
    }

    func applySettings() {
        call("ScratchEditor.setSettings(\(json(Settings.shared.editorSettings)))")
    }

    func applyKeymap() {
        let store = KeymapStore.shared
        call("ScratchEditor.setKeymap(\(json(store.bindings(for: .editor))), \(json(store.bindings(for: .app))))")
    }

    func exec(_ command: String) {
        call("ScratchEditor.exec(\(js(command)))")
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        call("ScratchEditor.focus()")
    }

    /// Formats the document; the completion receives an error message on failure.
    func format(compact: Bool, completion: @escaping (String?) -> Void) {
        guard isReady else { return completion("Editor is not ready") }
        let body = "return await ScratchEditor.\(compact ? "compact" : "format")()"
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let error):
                completion(error.localizedDescription)
            case .success(let value):
                let dict = value as? [String: Any]
                completion((dict?["ok"] as? Bool) == true ? nil : (dict?["error"] as? String ?? "Format failed"))
            }
        }
    }

    func text(completion: @escaping (String?) -> Void) {
        guard isReady else { return completion(nil) }
        webView.evaluateJavaScript("ScratchEditor.getText()") { result, _ in completion(result as? String) }
    }

    /// The document text and the main caret's UTF-16 offset.
    func textAndCursor(completion: @escaping (_ text: String?, _ cursor: Int) -> Void) {
        guard isReady else { return completion(nil, 0) }
        webView.evaluateJavaScript("ScratchEditor.getTextAndCursor()") { result, _ in
            let dict = result as? [String: Any]
            completion(dict?["text"] as? String, dict?["cursor"] as? Int ?? 0)
        }
    }

    func selectionText(completion: @escaping (String?) -> Void) {
        guard isReady else { return completion(nil) }
        webView.evaluateJavaScript("ScratchEditor.getSelectionText()") { result, _ in completion(result as? String) }
    }

    /// The non-empty selections, or the whole document (`whole == true`) when nothing is selected.
    func selections(completion: @escaping (_ ranges: [TextSelection], _ whole: Bool) -> Void) {
        guard isReady else { return completion([], true) }
        webView.evaluateJavaScript("ScratchEditor.getSelections()") { result, _ in
            let dict = result as? [String: Any] ?? [:]
            let ranges = (dict["ranges"] as? [[String: Any]] ?? []).compactMap { r -> TextSelection? in
                guard let from = r["from"] as? Int, let to = r["to"] as? Int, let text = r["text"] as? String else { return nil }
                return TextSelection(from: from, to: to, text: text)
            }
            completion(ranges, dict["whole"] as? Bool ?? true)
        }
    }

    func replace(_ replacements: [TextSelection]) {
        let list = replacements.map { ["from": $0.from, "to": $0.to, "text": $0.text] as [String: Any] }
        call("ScratchEditor.replaceRanges(\(json(list)))")
    }

    func insertAtCursors(_ text: String) {
        call("ScratchEditor.insertAtCursors(\(js(text)))")
    }

    /// Copies the rendered Markdown preview as rich text; false when the open scratch isn't Markdown.
    func copyRichText() {
        call("ScratchEditor.copyRichText()")
    }

    func setPreview(_ mode: PreviewMode) {
        call("ScratchEditor.setPreview(\(js(mode.rawValue)))")
    }

    func showDiff(left: (name: String, text: String), right: (name: String, text: String), language: Language) {
        call("ScratchEditor.showDiff(aName, aText, bName, bText, language)",
             arguments: ["aName": left.name, "aText": left.text, "bName": right.name, "bText": right.text,
                         "language": language.rawValue])
    }

    // MARK: HTTP response panel

    func httpStarted(scratchId: String, requests: [[String: Any]]) {
        call("ScratchEditor.httpStarted(\(js(scratchId)), \(json(requests)))")
    }

    func httpResult(scratchId: String, index: Int, result: [String: Any]) {
        call("ScratchEditor.httpResult(\(js(scratchId)), \(index), \(json(result)))")
    }

    func httpFinished(scratchId: String, cancelled: Bool) {
        call("ScratchEditor.httpFinished(\(js(scratchId)), \(cancelled))")
    }

    /// Selects a UTF-16 range in the current document and scrolls it into view.
    /// The open document's outline for Go to Symbol (nil if the editor isn't ready).
    func symbols(completion: @escaping (_ symbols: [DocumentSymbol], _ cursor: Int, _ truncated: Bool) -> Void) {
        guard isReady else { return completion([], 0, false) }
        webView.evaluateJavaScript("ScratchEditor.symbols()") { result, error in
            if let error { NSLog("ScratchPad: symbols failed: \(error)") }
            let dict = result as? [String: Any] ?? [:]
            let rows = dict["symbols"] as? [[Any]] ?? []
            completion(rows.compactMap(DocumentSymbol.init(row:)), dict["cursor"] as? Int ?? 0, dict["truncated"] as? Bool ?? false)
        }
    }

    /// `step` +1/-1 zooms the Markdown preview in or out, 0 resets it; false when the preview isn't the focus.
    func zoomPreview(_ step: Int, completion: @escaping (Bool) -> Void) {
        guard isReady else { return completion(false) }
        webView.evaluateJavaScript("ScratchEditor.zoomPreview(\(step))") { result, _ in completion(result as? Bool ?? false) }
    }

    func setSpecViewer(_ viewer: SpecViewer) {
        call("ScratchEditor.setSpecViewer(viewer)", arguments: ["viewer": viewer.rawValue])
    }

    /// The Markdown preview as a standalone page (nil for other languages); `forPrint` keeps blocks whole across pages.
    func previewDocument(title: String, forPrint: Bool, completion: @escaping (String?) -> Void) {
        guard isReady else { return completion(nil) }
        webView.callAsyncJavaScript("return await ScratchEditor.previewDocument(title, mode)",
                                    arguments: ["title": title, "mode": forPrint ? "print" : "html"],
                                    in: nil, in: .page) { result in
            if case .failure(let error) = result { NSLog("ScratchPad: preview export failed: \(error)") }
            completion((try? result.get()) as? String)
        }
    }

    /// Scrolls to a symbol and marks its line, without moving the cursor.
    func peekSymbol(at offset: Int) {
        call("ScratchEditor.peekSymbol(\(offset))")
    }

    /// Selects the chosen symbol's name, or (nil) scrolls back to where the picker was opened.
    func endSymbolPeek(select range: NSRange?) {
        if let range {
            call("ScratchEditor.endSymbolPeek(\(range.location), \(range.location + range.length))")
        } else {
            call("ScratchEditor.endSymbolPeek(null, null)")
        }
    }

    func reveal(_ range: NSRange) {
        call("ScratchEditor.reveal(\(range.location), \(range.location + range.length))")
    }

    /// Pushes any debounced change to native immediately.
    func flush(completion: @escaping () -> Void) {
        guard isReady else { return completion() }
        webView.evaluateJavaScript("ScratchEditor.flush()") { _, _ in completion() }
    }

    /// Synchronous variant for app termination: spins the run loop until WebKit answers
    /// (or the timeout passes), because async replies aren't delivered once AppKit waits on
    /// `terminateLater`.
    func flushSynchronously(timeout: TimeInterval = 1.0) {
        guard isReady else { return }
        var done = false
        webView.evaluateJavaScript("ScratchEditor.flush()") { _, _ in done = true }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        // One more pass so the "change" message posted by flush() is delivered.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    // MARK: Plumbing

    private func call(_ script: String, arguments: [String: Any] = [:]) {
        guard isReady else {
            queued.append((script, arguments))
            return
        }
        if arguments.isEmpty {
            webView.evaluateJavaScript(script) { _, error in
                if let error { NSLog("ScratchPad JS error: \(error) in \(script.prefix(120))") }
            }
        } else {
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                if case .failure(let error) = result { NSLog("ScratchPad JS error: \(error) in \(script.prefix(120))") }
            }
        }
    }

    private func js(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            isReady = true
            applySettings()
            applyKeymap()
            setSpecViewer(Settings.shared.specViewer)
            let pending = queued
            queued.removeAll()
            pending.forEach { call($0.script, arguments: $0.arguments) }
            delegate?.editorDidBecomeReady(self)
        case "change":
            if let id = body["id"] as? String, let text = body["text"] as? String {
                delegate?.editor(self, didChange: id, text: text)
            }
        case "status":
            var status = EditorStatus()
            status.line = body["line"] as? Int ?? 1
            status.column = body["column"] as? Int ?? 1
            status.cursors = body["cursors"] as? Int ?? 1
            status.selected = body["selected"] as? Int ?? 0
            status.length = body["length"] as? Int ?? 0
            delegate?.editor(self, status: status)
        case "pasteIntoEmpty":
            if let id = body["id"] as? String { delegate?.editor(self, didPasteIntoEmpty: id) }
        case "action":
            if let id = body["id"] as? String { delegate?.editor(self, requestsAction: id) }
        case "previewMode":
            previewAvailable = body["available"] as? Bool ?? false
            previewKind = body["kind"] as? String
            if let mode = PreviewMode(rawValue: body["mode"] as? String ?? "") {
                delegate?.editor(self, previewModeDidChange: mode)
            }
        case "diffClosed":
            delegate?.editorDidCloseDiff(self)
        case "pasteCurl":
            if let text = body["text"] as? String {
                delegate?.editor(self, didPasteCurl: text, separatorBefore: body["before"] as? Bool ?? false,
                                 separatorAfter: body["after"] as? Bool ?? false)
            }
        case "copyText":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "openResponse":
            if let text = body["text"] as? String {
                let language = Language(rawValue: body["language"] as? String ?? "") ?? Language.detect(text)
                delegate?.editor(self, openResponse: text, language: language)
            }
        case "copyRich":
            if let html = body["html"] as? String, let text = body["text"] as? String {
                RichClipboard.write(html: html, text: text)
                delegate?.editor(self, showMessage: "Copied the preview as rich text")
            }
        case "message":
            if let text = body["text"] as? String { delegate?.editor(self, showMessage: text) }
        case "runRequest":
            if let offset = body["offset"] as? Int { delegate?.editor(self, runRequestAt: offset) }
        case "openURL":
            if let raw = body["url"] as? String, let url = URL(string: raw),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

extension EditorController: WKNavigationDelegate {
    // Keep the editor page in place: dropping a file or clicking a link must not navigate away.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The sandboxed HTML preview iframe loads via srcdoc and the OpenAPI viewer frame loads the bundled
        // viewer.html; links clicked inside them open externally.
        if let frame = action.targetFrame, !frame.isMainFrame {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            let url = action.request.url
            let isViewer = url?.isFileURL == true && url?.lastPathComponent == "viewer.html"
            return decisionHandler(url?.scheme == "about" || isViewer ? .allow : .cancel)
        }
        let isEditorPage = (action.navigationType == .other || action.navigationType == .reload)
            && action.request.url?.isFileURL == true && action.request.url?.lastPathComponent == "index.html"
        decisionHandler(isEditorPage ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.reload()
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: EditorController?
    init(_ target: EditorController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handle(body)
    }
}

/// Routes Edit-menu undo/redo/select-all to CodeMirror (the browser's own versions don't know about
/// CodeMirror's history or its virtualised document) and trims WebKit's page-level context menu.
private final class EditorWebView: WKWebView {
    var onCommand: ((String) -> Void)?

    @objc func undo(_ sender: Any?) { onCommand?("undo") }
    @objc func redo(_ sender: Any?) { onCommand?("redo") }
    override func selectAll(_ sender: Any?) { onCommand?("selectAll") }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)), #selector(redo(_:)), #selector(selectAll(_:)): return true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let keep: Set<String> = ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste",
                                 "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate",
                                 "WKMenuItemIdentifierSpeechMenu", "WKMenuItemIdentifierShareMenu"]
        menu.items.removeAll { item in
            guard let id = item.identifier?.rawValue else { return false }
            return id.hasPrefix("WKMenuItemIdentifier") && !keep.contains(id)
        }
        super.willOpenMenu(menu, with: event)
    }
}

/// Writes formatted content the way browsers do: HTML for apps that take it, RTF for the rest
/// (TextEdit, older Cocoa apps), and plain text as the fallback.
enum RichClipboard {
    static func write(html: String, text: String) {
        let page = "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family: -apple-system, Helvetica, sans-serif\">\(html)</body></html>"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(page, forType: .html)
        if let data = page.data(using: .utf8),
           let attributed = try? NSAttributedString(data: data, options: [
               .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
           ], documentAttributes: nil),
           let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(text, forType: .string)
    }
}

/// One entry of a document's outline. Offsets are UTF-16, like NSString's.
struct DocumentSymbol {
    let name: String
    let kind: String
    /// What gets selected when you jump to it (usually the name).
    let range: NSRange
    /// Where the symbol's body ends, to tell which symbol the cursor is in.
    let end: Int
    let depth: Int
    let line: Int
    let container: String
    let detail: String

    init(name: String, kind: String, range: NSRange, end: Int, depth: Int, line: Int, container: String = "", detail: String = "") {
        self.name = name
        self.kind = kind
        self.range = range
        self.end = end
        self.depth = depth
        self.line = line
        self.container = container
        self.detail = detail
    }

    init?(row: [Any]) {
        guard row.count >= 9, let name = row[0] as? String, let kind = row[1] as? String,
              let from = row[2] as? Int, let to = row[3] as? Int else { return nil }
        self.init(name: name, kind: kind, range: NSRange(location: from, length: max(0, to - from)),
                  end: row[4] as? Int ?? to, depth: row[5] as? Int ?? 0, line: row[6] as? Int ?? 1,
                  container: row[7] as? String ?? "", detail: row[8] as? String ?? "")
    }

    /// Icon and colour for the picker row, by kind.
    var tile: (symbol: String, tint: NSColor) {
        switch kind {
        case "class", "schema": return ("c.square.fill", .systemOrange)
        case "struct": return ("s.square.fill", .systemOrange)
        case "interface": return ("i.square.fill", .systemTeal)
        case "enum": return ("e.square.fill", .systemYellow)
        case "enumMember": return ("e.circle", .systemYellow)
        case "function": return ("f.square.fill", .systemPurple)
        case "method": return ("m.square.fill", .systemPurple)
        case "constructor": return ("hammer.fill", .systemPurple)
        case "property", "field": return ("p.square.fill", .systemBlue)
        case "variable": return ("v.square.fill", .systemBlue)
        case "constant": return ("k.square.fill", .systemIndigo)
        case "type": return ("t.square.fill", .systemTeal)
        case "namespace", "module": return ("shippingbox.fill", .systemBrown)
        case "test": return ("checkmark.diamond.fill", .systemGreen)
        case "selector": return ("number", .systemPink)
        case "atRule": return ("at", .systemPink)
        case "object": return ("curlybraces", .systemYellow)
        case "array": return ("square.stack.3d.up", .systemOrange)
        case "string": return ("textformat.abc", .systemRed)
        case "number": return ("number", .systemBlue)
        case "boolean": return ("switch.2", .systemGreen)
        case "null": return ("circle.slash", .systemGray)
        case "key": return ("key.fill", .systemTeal)
        case "element": return ("chevron.left.forwardslash.chevron.right", .systemRed)
        case "heading": return ("textformat.size", .systemBlue)
        case "section": return ("bookmark.fill", .systemGray)
        case "table": return ("tablecells", .systemTeal)
        case "view": return ("eye", .systemTeal)
        case "index": return ("list.bullet.indent", .systemGray)
        case "cte": return ("square.on.square", .systemGray)
        case "query": return ("magnifyingglass", .systemIndigo)
        case "statement": return ("text.alignleft", .systemGray)
        case "event": return ("bolt.fill", .systemYellow)
        case "request", "operation": return ("network", .systemGreen)
        case "route": return ("arrow.triangle.branch", .systemGreen)
        case "component": return ("puzzlepiece.fill", .systemGray)
        case "column": return ("rectangle.split.3x1", .systemGreen)
        case "document": return ("doc.fill", .systemGray)
        default: return ("circle.fill", .systemGray)
        }
    }

    /// "method", "enum member", "at-rule"… for the picker's kind filter and search.
    var kindLabel: String {
        switch kind {
        case "enumMember": return "enum member"
        case "atRule": return "at-rule"
        case "cte": return "CTE"
        default: return kind
        }
    }
}
