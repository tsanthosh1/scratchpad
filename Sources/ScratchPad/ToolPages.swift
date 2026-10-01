import AppKit
import CryptoKit

/// Base for dev tool pages: per-tool saved values and shared card buttons.
class ToolPageController: NSViewController {
    let toolId: String
    var onOpenInScratch: ((String) -> Void)?

    init(toolId: String) {
        self.toolId = toolId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func value(_ key: String) -> String? { Settings.shared.toolValue(toolId, key) }
    func store(_ key: String, _ value: String) { Settings.shared.setToolValue(toolId, key, value) }
    func flag(_ key: String, default fallback: Bool = false) -> Bool { value(key).map { $0 == "1" } ?? fallback }
    func setFlag(_ key: String, _ on: Bool) { store(key, on ? "1" : "0") }

    /// Where the caret goes when the page opens.
    func focus() {}
    /// What ⌘⇧C copies.
    var primaryOutput: String? { nil }

    func pasteButton(_ target: CardTextView) -> ToolActionButton {
        ToolActionButton(title: "Paste", symbol: "doc.on.clipboard", tip: "Replace with the clipboard") { [weak target] in
            guard let target, let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
            target.replaceAll(text)
            target.window?.makeFirstResponder(target)
        }
    }

    func clearButton(_ target: CardTextView) -> ToolActionButton {
        ToolActionButton(title: nil, symbol: "xmark", tip: "Clear") { [weak target] in
            guard let target else { return }
            target.replaceAll("")
            target.window?.makeFirstResponder(target)
        }
    }

    func copyButton(prominent: Bool = false, title: String = "Copy", _ text: @escaping () -> String) -> ToolActionButton {
        ToolActionButton(title: title, symbol: "doc.on.doc", tip: "Copy to the clipboard", style: prominent ? .prominent : .plain) { button in
            let value = text()
            guard !value.isEmpty else { return NSSound.beep() }
            ToolUI.copy(value)
            button.flash()
        }
    }

    func newScratchButton(_ text: @escaping () -> String) -> ToolActionButton {
        ToolActionButton(title: nil, symbol: "square.and.pencil", tip: "Open in a new scratch") { [weak self] in
            let value = text()
            guard !value.isEmpty else { return NSSound.beep() }
            self?.onOpenInScratch?(value)
        }
    }

    func chip(_ title: String, key: String, tip: String? = nil, default fallback: Bool = false,
              changed: @escaping () -> Void) -> ToolActionButton {
        let chip = ToolActionButton(title: title, symbol: nil, tip: tip, style: .chip) { [weak self] button in
            self?.setFlag(key, button.isOn)
            changed()
        }
        chip.isOn = flag(key, default: fallback)
        return chip
    }

    func choice(_ key: String, _ options: [(id: String, title: String)]) -> String {
        let saved = value(key)
        return options.contains { $0.id == saved } ? saved! : options[0].id
    }

    func segmented(_ key: String, _ options: [(id: String, title: String)], changed: @escaping () -> Void) -> ClosureSegmented {
        let current = choice(key, options)
        let control = ClosureSegmented(options.map(\.title), selected: options.firstIndex { $0.id == current } ?? 0)
        control.onChange = { [weak self] index in
            self?.store(key, options[index].id)
            changed()
        }
        return control
    }

    func popup(_ key: String, _ options: [(id: String, title: String)], changed: @escaping () -> Void) -> ClosurePopUp {
        let current = choice(key, options)
        let control = ClosurePopUp(options.map(\.title), selected: options.firstIndex { $0.id == current } ?? 0)
        control.onChange = { [weak self] index in
            self?.store(key, options[index].id)
            changed()
        }
        return control
    }
}

private func transform(_ id: String) -> (String) throws -> String {
    guard case .map(let run)? = Transforms.byId[id]?.kind else { return { $0 } }
    return run
}

private func hex<S: Sequence>(_ bytes: S, uppercase: Bool = false) -> String where S.Element == UInt8 {
    bytes.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func base64URLData(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

// MARK: - Two-way converters (Base64, URL, HTML, strings, hex)

/// Plain text on the left, encoded on the right; typing on either side converts to the other.
class TwoWayPage: ToolPageController {
    struct Spec {
        var left: String
        var right: String
        var leftPlaceholder = "Type or paste text"
        var rightPlaceholder: String
        var encode: (String) throws -> String
        var decode: (String) throws -> String
    }

    private let specBuilder: (TwoWayPage) -> Spec
    private var spec: Spec!
    let left = CardTextView(editable: true)
    let right = CardTextView(editable: true)
    private(set) var leftCard: ToolCard!
    private(set) var rightCard: ToolCard!
    private let split = GapSplitView()
    private var editedRight = false
    /// Filled in by subclasses before the view loads.
    var options: [NSView] = []
    var extraLeftActions: [NSView] = []
    var bottom: NSView?

    init(toolId: String, spec: @escaping (TwoWayPage) -> Spec) {
        specBuilder = spec
        super.init(toolId: toolId)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called with the plain text after every conversion.
    func plainTextChanged(_ text: String) {}

    override func loadView() {
        spec = specBuilder(self)
        leftCard = ToolCard.text(spec.left, left, actions: extraLeftActions + [pasteButton(left), clearButton(left), copyButton { [weak self] in self?.left.string ?? "" }])
        rightCard = ToolCard.text(spec.right, right, actions: [pasteButton(right), clearButton(right),
                                                               copyButton(prominent: true) { [weak self] in self?.right.string ?? "" }])
        left.setPlaceholder(spec.leftPlaceholder)
        right.setPlaceholder(spec.rightPlaceholder)
        left.onChange = { [weak self] in self?.convert(fromRight: false) }
        right.onChange = { [weak self] in self?.convert(fromRight: true) }
        split.addArrangedSubview(leftCard)
        split.addArrangedSubview(rightCard)

        var views: [NSView] = []
        if !options.isEmpty { views.append(ToolUI.row(options + [ToolUI.spacer()], spacing: 8)) }
        views.append(split)
        if let bottom { views.append(bottom) }
        split.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page(views)

        editedRight = value("side") == "right"
        (editedRight ? right : left).string = value("text") ?? ""
        refresh()
    }

    /// Re-runs the conversion from the side last typed in (after an option changes).
    func refresh() {
        spec = specBuilder(self)
        convert(fromRight: editedRight)
    }

    private func convert(fromRight: Bool) {
        editedRight = fromRight
        let (source, target) = fromRight ? (right, left) : (left, right)
        let (sourceCard, targetCard) = fromRight ? (rightCard!, leftCard!) : (leftCard!, rightCard!)
        store("side", fromRight ? "right" : "left")
        store("text", source.string)
        sourceCard.setMeta(ToolUI.describe(source.string))
        guard !source.string.isEmpty else {
            target.string = ""
            targetCard.setMeta("")
            return plainTextChanged("")
        }
        do {
            target.string = try (fromRight ? spec.decode : spec.encode)(source.string)
            targetCard.setMeta(ToolUI.describe(target.string))
        } catch {
            sourceCard.setMeta(error.localizedDescription, isError: true)
        }
        plainTextChanged(left.string)
    }

    override func focus() { view.window?.makeFirstResponder(editedRight ? right : left) }
    override var primaryOutput: String? { editedRight ? left.string : right.string }
}

final class Base64Page: TwoWayPage {
    init() {
        super.init(toolId: "base64") { page in
            let urlSafe = page.flag("urlSafe")
            return .init(left: "Text", right: urlSafe ? "Base64URL" : "Base64", rightPlaceholder: "Paste Base64 to decode",
                         encode: { urlSafe ? base64URL(Data($0.utf8)) : Data($0.utf8).base64EncodedString() },
                         decode: transform("base64Decode"))
        }
        options = [chip("URL-safe", key: "urlSafe", tip: "Use - and _ and drop the = padding") { [weak self] in self?.refresh() }]
        extraLeftActions = [ToolActionButton(title: "File…", symbol: "doc.badge.arrow.up", tip: "Encode a file") { [weak self] in
            self?.encodeFile()
        }]
    }

    required init?(coder: NSCoder) { fatalError() }

    private func encodeFile() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            self.left.string = ""
            self.right.string = self.flag("urlSafe") ? base64URL(data) : data.base64EncodedString()
            self.leftCard.setMeta("Encoded \(url.lastPathComponent) · \(ToolUI.bytes(data.count))")
            self.rightCard.setMeta(ToolUI.describe(self.right.string))
        }
    }
}

final class URLPage: TwoWayPage {
    private let parts = ScrollStack()
    private lazy var partsCard = ToolCard(title: "URL Parts", content: parts, footer: false)
    private var partsHeight: NSLayoutConstraint!

    init() {
        super.init(toolId: "url") { page in
            let full = page.choice("scope", Self.scopes) == "full"
            let plus = page.flag("plus")
            return .init(left: "Decoded", right: "Encoded", rightPlaceholder: "Paste percent-encoded text",
                         encode: { text in
                             var encoded: String
                             if full {
                                 var allowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed)
                                 allowed.insert(charactersIn: "#:?&=")
                                 allowed.remove(" ")
                                 encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
                             } else {
                                 encoded = try transform("urlEncode")(text)
                             }
                             return plus ? encoded.replacingOccurrences(of: "%20", with: "+") : encoded
                         },
                         decode: transform("urlDecode"))
        }
        options = [
            segmented("scope", Self.scopes) { [weak self] in self?.refresh() },
            chip("Spaces as +", key: "plus", tip: "Form encoding (application/x-www-form-urlencoded)") { [weak self] in self?.refresh() },
        ]
        partsHeight = partsCard.heightAnchor.constraint(equalToConstant: 0)
        partsHeight.isActive = true
        partsCard.isHidden = true
        bottom = partsCard
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let scopes = [(id: "component", title: "Component"), (id: "full", title: "Full URL")]

    override func plainTextChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme, let host = components.host,
              !host.isEmpty else {
            partsCard.isHidden = true
            return
        }
        var rows: [(String, String)] = [("Scheme", scheme), ("Host", host)]
        if let port = components.port { rows.append(("Port", String(port))) }
        if !components.path.isEmpty { rows.append(("Path", components.path)) }
        for item in components.queryItems ?? [] { rows.append(("? \(item.name)", item.value ?? "")) }
        if let fragment = components.fragment { rows.append(("# Fragment", fragment)) }
        parts.setViews(rows.map { title, value in
            let row = ValueRow(title: title, titleWidth: 110)
            row.value = value
            return row
        })
        partsCard.isHidden = false
        view.layoutSubtreeIfNeeded()
        partsHeight.constant = min(parts.fittingHeight + 40, 240)
    }
}

final class HTMLPage: TwoWayPage {
    init() {
        super.init(toolId: "html") { page in
            let nonASCII = page.flag("nonAscii")
            return .init(left: "Text", right: "Escaped HTML", rightPlaceholder: "Paste HTML with &entities;",
                         encode: { text in
                             let escaped = try transform("htmlEscape")(text)
                             guard nonASCII else { return escaped }
                             return escaped.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "&#x%X;", $0.value) }.joined()
                         },
                         decode: transform("htmlUnescape"))
        }
        options = [chip("Escape non-ASCII", key: "nonAscii", tip: "Also write é, ✓, emoji… as &#x…; references") { [weak self] in
            self?.refresh()
        }]
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class EscapePage: TwoWayPage {
    private static let formats = [(id: "json", title: "JSON / Java String"), (id: "unicode", title: "Unicode \\uXXXX")]

    init() {
        super.init(toolId: "escape") { page in
            let unicode = page.choice("format", Self.formats) == "unicode"
            let quotes = page.flag("quotes")
            return .init(left: "Raw Text", right: unicode ? "Unicode Escaped" : "String Literal",
                         rightPlaceholder: unicode ? "Paste text with \\u escapes" : "Paste an escaped string",
                         encode: { text in
                             if unicode { return try transform("unicodeEscape")(text) }
                             let escaped = try transform("jsonEscape")(text)
                             return quotes ? "\"\(escaped)\"" : escaped
                         },
                         decode: transform(unicode ? "unicodeUnescape" : "jsonUnescape"))
        }
        options = [
            segmented("format", Self.formats) { [weak self] in self?.refresh() },
            chip("Wrap in quotes", key: "quotes", tip: "Add the surrounding \"…\" (JSON / Java only)") { [weak self] in self?.refresh() },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class HexPage: TwoWayPage {
    private static let separators = [(id: "", title: "None"), (id: " ", title: "Space"), (id: ":", title: "Colon")]

    init() {
        super.init(toolId: "hex") { page in
            let separator = page.choice("separator", Self.separators)
            let upper = page.flag("upper")
            return .init(left: "Text (UTF-8)", right: "Hex", rightPlaceholder: "Paste hex (spaces, colons and 0x are fine)",
                         encode: { text in Data(text.utf8).map { String(format: upper ? "%02X" : "%02x", $0) }.joined(separator: separator) },
                         decode: transform("hexDecode"))
        }
        options = [
            ToolUI.caption("Separator"),
            segmented("separator", Self.separators) { [weak self] in self?.refresh() },
            chip("Uppercase", key: "upper") { [weak self] in self?.refresh() },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - JWT

final class JWTPage: ToolPageController {
    private let token = CardTextView(editable: true)
    private let header = CardTextView(editable: false)
    private let payload = CardTextView(editable: false)
    private lazy var tokenCard = ToolCard.text("Encoded Token", token, actions: [pasteButton(token), clearButton(token)])
    private lazy var headerCard = ToolCard.text("Header", header, actions: [copyButton { [weak self] in self?.header.string ?? "" }])
    private lazy var payloadCard = ToolCard.text("Payload", payload, actions: [
        newScratchButton { [weak self] in self?.payload.string ?? "" },
        copyButton(prominent: true) { [weak self] in self?.payload.string ?? "" },
    ])
    private let claims = ScrollStack()
    private lazy var claimsCard = ToolCard(title: "Claims", content: claims, footer: false)
    private let algorithm = Badge()
    private let type = Badge()
    private let expiry = Badge()
    private let signature = Badge()
    private let secret = NSSecureTextField()

    init() { super.init(toolId: "jwt") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        token.setPlaceholder("Paste a JWT (with or without “Bearer ”)")
        token.onChange = { [weak self] in self?.update() }
        secret.placeholderString = "Secret to verify HS256/384/512"
        secret.delegate = self
        secret.widthAnchor.constraint(equalToConstant: 230).isActive = true
        tokenCard.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let status = ToolUI.row([algorithm, type, expiry, ToolUI.spacer(), secret, signature], spacing: 6)
        let sideSplit = GapSplitView()
        sideSplit.sideBySideMinWidth = nil
        sideSplit.isVertical = false
        sideSplit.ratio = 0.45
        sideSplit.addArrangedSubview(headerCard)
        sideSplit.addArrangedSubview(claimsCard)
        let split = GapSplitView()
        split.ratio = 0.55
        split.addArrangedSubview(payloadCard)
        split.addArrangedSubview(sideSplit)
        split.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page([tokenCard, status, split])
        token.string = value("token") ?? ""
        update()
    }

    override func focus() { view.window?.makeFirstResponder(token) }
    override var primaryOutput: String? { payload.string }

    private func update() {
        store("token", token.string)
        let raw = token.string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[Bb]earer\s+"#, with: "", options: .regularExpression)
        colorSegments()
        header.string = ""
        payload.string = ""
        claims.setViews([])
        [algorithm, type, expiry, signature].forEach { $0.show(nil) }
        tokenCard.setMeta("")
        guard !raw.isEmpty else { return }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 2 else {
            return tokenCard.setMeta("A JWT has three parts separated by dots", isError: true)
        }
        guard let headerJSON = json(parts[0]), let payloadJSON = json(parts[1]) else {
            return tokenCard.setMeta("The header or payload isn't Base64URL-encoded JSON", isError: true)
        }
        header.string = pretty(headerJSON)
        payload.string = pretty(payloadJSON)
        tokenCard.setMeta("\(raw.count) characters · signature \(parts.count == 3 && !parts[2].isEmpty ? "present" : "missing")")

        let alg = headerJSON["alg"] as? String
        algorithm.show(alg ?? "no alg", color: .systemBlue)
        type.show(headerJSON["typ"] as? String, color: .systemGray)
        showExpiry(payloadJSON)
        showClaims(payloadJSON)
        verify(parts: parts, alg: alg)
    }

    private func json(_ part: String) -> [String: Any]? {
        base64URLData(part).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func pretty(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func colorSegments() {
        guard let storage = token.textStorage else { return }
        let text = storage.string as NSString
        let colors: [NSColor] = [.systemPink, .systemPurple, .systemTeal]
        var segment = 0
        var start = 0
        storage.beginEditing()
        for i in 0...text.length {
            if i == text.length || text.character(at: i) == 46 /* . */ {
                storage.addAttribute(.foregroundColor, value: colors[min(segment, 2)], range: NSRange(location: start, length: i - start))
                if i < text.length { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: i, length: 1)) }
                segment += 1
                start = i + 1
            }
        }
        storage.endEditing()
    }

    private func date(_ value: Any?) -> Date? {
        (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    private func showExpiry(_ payload: [String: Any]) {
        let relative = RelativeDateTimeFormatter()
        let now = Date()
        if let nbf = date(payload["nbf"]), nbf > now {
            expiry.show("Not valid until \(relative.localizedString(for: nbf, relativeTo: now))", color: .systemOrange, symbol: "⏳")
        } else if let exp = date(payload["exp"]) {
            if exp < now {
                expiry.show("Expired \(relative.localizedString(for: exp, relativeTo: now))", color: .systemRed, symbol: "✕")
            } else {
                expiry.show("Valid · expires \(relative.localizedString(for: exp, relativeTo: now))", color: .systemGreen, symbol: "✓")
            }
        } else {
            expiry.show("No expiry", color: .systemGray)
        }
    }

    private func showClaims(_ payload: [String: Any]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let relative = RelativeDateTimeFormatter()
        let known = [("iss", "Issuer"), ("sub", "Subject"), ("aud", "Audience"), ("iat", "Issued at"), ("nbf", "Not before"),
                     ("exp", "Expires"), ("jti", "Token ID"), ("scope", "Scope")]
        var rows: [NSView] = []
        for (key, title) in known {
            guard let raw = payload[key] else { continue }
            let row = ValueRow(title: title, titleWidth: 90)
            if ["iat", "nbf", "exp"].contains(key), let d = date(raw) {
                row.value = "\(formatter.string(from: d)) (\(relative.localizedString(for: d, relativeTo: Date())))"
            } else if let list = raw as? [Any] {
                row.value = list.map { "\($0)" }.joined(separator: ", ")
            } else {
                row.value = "\(raw)"
            }
            rows.append(row)
        }
        claims.setViews(rows)
    }

    private func verify(parts: [String], alg: String?) {
        let key = secret.stringValue
        guard !key.isEmpty else { return }
        guard parts.count == 3, let alg, alg.hasPrefix("HS") else {
            return signature.show("Only HS256/384/512 can be checked with a secret", color: .systemGray)
        }
        let message = Data("\(parts[0]).\(parts[1])".utf8)
        let symmetric = SymmetricKey(data: Data(key.utf8))
        let expected: Data
        switch alg {
        case "HS256": expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case "HS384": expected = Data(HMAC<SHA384>.authenticationCode(for: message, using: symmetric))
        case "HS512": expected = Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        default: return signature.show("Unsupported \(alg)", color: .systemGray)
        }
        if base64URL(expected) == parts[2] {
            signature.show("Signature verified", color: .systemGreen, symbol: "✓")
        } else {
            signature.show("Invalid signature", color: .systemRed, symbol: "✕")
        }
    }
}

extension JWTPage: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { update() }
}

// MARK: - Hash

final class HashPage: ToolPageController, NSTextFieldDelegate {
    private let input = CardTextView(editable: true)
    private lazy var inputCard = ToolCard.text("Input", input, actions: [
        ToolActionButton(title: "File…", symbol: "doc.badge.arrow.up", tip: "Hash a file") { [weak self] in self?.chooseFile() },
        pasteButton(input), clearButton(input),
    ])
    private let algorithms = ["MD5", "SHA-1", "SHA-256", "SHA-384", "SHA-512"]
    private lazy var rows = algorithms.map { ValueRow(title: $0, titleWidth: 100) }
    private lazy var resultsCard = ToolCard(title: "Digests", content: ScrollStack(rows), footer: false)
    private let key = NSTextField()
    private let compare = NSTextField()
    private let compareBadge = Badge()
    private var file: (name: String, data: Data)?

    init() { super.init(toolId: "hash") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        input.setPlaceholder("Type or paste text, or choose a file")
        input.onChange = { [weak self] in
            self?.file = nil
            self?.update()
        }
        key.placeholderString = "HMAC key (optional)"
        compare.placeholderString = "Paste a hash to compare"
        for field in [key, compare] {
            field.delegate = self
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        key.widthAnchor.constraint(equalToConstant: 190).isActive = true
        compare.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let upper = chip("Uppercase", key: "upper") { [weak self] in self?.update() }
        let options = ToolUI.row([upper, key, ToolUI.spacer(), compare, compareBadge])
        let split = GapSplitView()
        split.sideBySideMinWidth = 820
        split.ratio = 0.42
        split.addArrangedSubview(inputCard)
        split.addArrangedSubview(resultsCard)
        split.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page([options, split])
        input.string = value("text") ?? ""
        update()
    }

    override func focus() { view.window?.makeFirstResponder(input) }
    override var primaryOutput: String? { rows[2].value }

    func controlTextDidChange(_ obj: Notification) { update() }

    private func chooseFile() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            self.input.string = ""
            self.file = (url.lastPathComponent, data)
            self.update()
        }
    }

    private func update() {
        if file == nil { store("text", input.string) }
        let data = file?.data ?? Data(input.string.utf8)
        let upper = flag("upper")
        let hmacKey = key.stringValue.isEmpty ? nil : SymmetricKey(data: Data(key.stringValue.utf8))
        func digest<H: HashFunction>(_: H.Type) -> String {
            if let hmacKey { return hex(HMAC<H>.authenticationCode(for: data, using: hmacKey), uppercase: upper) }
            return hex(H.hash(data: data), uppercase: upper)
        }
        let empty = file == nil && input.string.isEmpty
        let values = empty ? Array(repeating: "", count: 5)
            : [digest(Insecure.MD5.self), digest(Insecure.SHA1.self), digest(SHA256.self), digest(SHA384.self), digest(SHA512.self)]
        for (row, (name, value)) in zip(rows, zip(algorithms, values)) {
            row.title = hmacKey == nil ? name : "HMAC-\(name.replacingOccurrences(of: "-", with: ""))"
            row.value = value
        }
        inputCard.setMeta(file.map { "\($0.name) · \(ToolUI.bytes($0.data.count))" } ?? (empty ? "" : "\(ToolUI.bytes(data.count)) of UTF-8"))

        let wanted = compare.stringValue.lowercased().filter { $0.isHexDigit }
        var match: String?
        for (row, name) in zip(rows, algorithms) {
            row.isMatch = !wanted.isEmpty && row.value.lowercased() == wanted
            if row.isMatch { match = name }
        }
        if wanted.isEmpty || empty {
            compareBadge.show(nil)
        } else if let match {
            compareBadge.show("Matches \(match)", color: .systemGreen, symbol: "✓")
        } else {
            compareBadge.show("No match", color: .systemRed, symbol: "✕")
        }
    }
}

// MARK: - Case converter

final class CasePage: ToolPageController {
    private let input = CardTextView(editable: true)
    private lazy var inputCard = ToolCard.text("Input", input, actions: [pasteButton(input), clearButton(input)])
    private let cases = ["camel", "pascal", "snake", "constant", "kebab", "dot", "title", "sentence", "upper", "lower"]
    private lazy var rows = cases.map { ValueRow(title: Transforms.byId[$0]?.title ?? $0, titleWidth: 130) }

    init() { super.init(toolId: "case") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        input.setPlaceholder("Words, a phrase or an identifier — e.g. user account id")
        input.onChange = { [weak self] in self?.update() }
        inputCard.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let list = ToolCard(title: "Click a row to copy", content: ScrollStack(rows), footer: false)
        list.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page([inputCard, list])
        input.string = value("text") ?? ""
        update()
    }

    override func focus() { view.window?.makeFirstResponder(input) }

    private func update() {
        store("text", input.string)
        inputCard.setMeta(ToolUI.describe(input.string))
        for (row, id) in zip(rows, cases) {
            row.value = input.string.isEmpty ? "" : (try? transform(id)(input.string)) ?? ""
        }
    }
}

// MARK: - Line tools

final class LinesPage: ToolPageController {
    private let input = CardTextView(editable: true)
    private let output = CardTextView(editable: false)
    private lazy var inputCard = ToolCard.text("Input", input, actions: [pasteButton(input), clearButton(input)])
    private lazy var outputCard = ToolCard.text("Result", output, actions: [
        newScratchButton { [weak self] in self?.output.string ?? "" },
        copyButton(prominent: true) { [weak self] in self?.output.string ?? "" },
    ])

    private static let splits = [(id: "lines", title: "Lines"), (id: "comma", title: "Commas"), (id: "space", title: "Whitespace")]
    private static let sorts = [(id: "none", title: "Keep Order"), (id: "asc", title: "A → Z"), (id: "desc", title: "Z → A"),
                                (id: "length", title: "Length"), (id: "numeric", title: "Numeric"), (id: "shuffle", title: "Shuffle")]
    private static let joins = [(id: "lines", title: "One per Line"), (id: "comma", title: "Comma-separated"),
                                (id: "space", title: "Space-separated"), (id: "json", title: "JSON Array"), (id: "sql", title: "SQL IN (…)")]
    private static let quotes = [(id: "none", title: "No Quotes"), (id: "single", title: "'Single'"), (id: "double", title: "\"Double\"")]

    init() { super.init(toolId: "lines") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        input.setPlaceholder("One item per line (or pick another separator above)")
        input.onChange = { [weak self] in self?.update() }
        let refresh: () -> Void = { [weak self] in self?.update() }
        let cleanRow = ToolUI.row([
            ToolUI.caption("Split"), segmented("split", Self.splits, changed: refresh),
            chip("Trim", key: "trim", default: true, changed: refresh),
            chip("Remove Empty", key: "removeEmpty", default: true, changed: refresh),
            chip("Unique", key: "unique", changed: refresh),
            chip("Ignore Case", key: "ignoreCase", tip: "For Unique and sorting", changed: refresh),
            chip("Reverse", key: "reverse", changed: refresh),
            ToolUI.spacer(),
        ])
        let outRow = ToolUI.row([
            ToolUI.caption("Sort"), popup("sort", Self.sorts, changed: refresh),
            ToolUI.caption("Output"), popup("join", Self.joins, changed: refresh),
            popup("quote", Self.quotes, changed: refresh),
            ToolUI.spacer(),
        ])
        outRow.setCustomSpacing(18, after: outRow.arrangedSubviews[1])
        let split = GapSplitView()
        split.addArrangedSubview(inputCard)
        split.addArrangedSubview(outputCard)
        split.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page([cleanRow, outRow, split], spacing: 10)
        input.string = value("text") ?? ""
        update()
    }

    override func focus() { view.window?.makeFirstResponder(input) }
    override var primaryOutput: String? { output.string }

    private func update() {
        store("text", input.string)
        let text = input.string
        var items: [String]
        switch choice("split", Self.splits) {
        case "comma": items = text.components(separatedBy: ",")
        case "space": items = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        default:
            items = Transforms.splitLines(text)
            if text.hasSuffix("\n") { items.removeLast() }
        }
        if text.isEmpty { items = [] }
        let count = items.count
        let ignoreCase = flag("ignoreCase")
        if flag("trim", default: true) { items = items.map { $0.trimmingCharacters(in: .whitespaces) } }
        if flag("removeEmpty", default: true) { items = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        var duplicates = 0
        if flag("unique") {
            var seen = Set<String>()
            items = items.filter { seen.insert(ignoreCase ? $0.lowercased() : $0).inserted }
            duplicates = count - items.count
        }
        switch choice("sort", Self.sorts) {
        case "asc", "desc":
            let ascending = choice("sort", Self.sorts) == "asc"
            items.sort { a, b in
                let order = ignoreCase ? a.localizedCaseInsensitiveCompare(b) : a.localizedStandardCompare(b)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case "length": items.sort { $0.count < $1.count }
        case "numeric": items.sort { (Double($0.trimmingCharacters(in: .whitespaces)) ?? .infinity) < (Double($1.trimmingCharacters(in: .whitespaces)) ?? .infinity) }
        case "shuffle": items.shuffle()
        default: break
        }
        if flag("reverse") { items.reverse() }

        let join = choice("join", Self.joins)
        if join == "json" {
            let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .withoutEscapingSlashes])
            output.string = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        } else {
            let quote = join == "sql" ? "single" : choice("quote", Self.quotes)
            let quoted = items.map { item -> String in
                switch quote {
                case "single": return "'" + item.replacingOccurrences(of: "'", with: "''") + "'"
                case "double": return "\"" + item.replacingOccurrences(of: "\"", with: "\\\"") + "\""
                default: return item
                }
            }
            switch join {
            case "comma": output.string = quoted.joined(separator: ", ")
            case "space": output.string = quoted.joined(separator: " ")
            case "sql": output.string = "(" + quoted.joined(separator: ", ") + ")"
            default: output.string = quoted.joined(separator: "\n")
            }
        }
        if text.isEmpty { output.string = "" }
        inputCard.setMeta(count == 0 ? "" : "\(count) \(count == 1 ? "item" : "items")")
        var summary = count == 0 ? "" : "\(items.count) \(items.count == 1 ? "item" : "items")"
        if duplicates > 0 { summary += " · \(duplicates) duplicate\(duplicates == 1 ? "" : "s") removed" }
        outputCard.setMeta(summary)
    }
}

// MARK: - Text statistics

final class TextStatsPage: ToolPageController {
    private let input = CardTextView(editable: true)
    private lazy var inputCard = ToolCard.text("Text", input, actions: [
        ToolActionButton(title: "Trim", symbol: nil, tip: "Trim leading and trailing whitespace") { [weak self] in self?.apply("trim") },
        ToolActionButton(title: "Collapse", symbol: nil, tip: "Collapse runs of spaces and tabs") { [weak self] in self?.apply("collapseSpaces") },
        ToolActionButton(title: "Reverse", symbol: nil, tip: "Reverse the text") { [weak self] in self?.apply("reverse") },
        pasteButton(input), clearButton(input),
    ])
    private let titles = ["Characters", "Without Spaces", "Words", "Unique Words", "Lines", "Sentences", "Paragraphs",
                          "UTF-8 Bytes", "Reading Time", "Speaking Time"]
    private lazy var tiles = titles.map(StatTile.init)

    init() { super.init(toolId: "text") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        input.setPlaceholder("Type or paste text to count")
        input.onChange = { [weak self] in self?.update() }
        let grid = NSGridView(views: stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) as [NSView] })
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        let gridScroll = ScrollStack([grid], insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        let statsCard = ToolCard(title: "Statistics", content: gridScroll, footer: false)
        let split = GapSplitView()
        split.ratio = 0.6
        split.addArrangedSubview(inputCard)
        split.addArrangedSubview(statsCard)
        split.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page([split])
        input.string = value("text") ?? ""
        update()
    }

    override func focus() { view.window?.makeFirstResponder(input) }

    private func apply(_ id: String) {
        guard !input.string.isEmpty, let result = try? transform(id)(input.string) else { return NSSound.beep() }
        input.replaceAll(result)
    }

    private func update() {
        let text = input.string
        store("text", text)
        let words = text.split { $0.isWhitespace || $0.isNewline }
        var sentences = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, _, _ in sentences += 1 }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let unique = Set(words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }).count
        func minutes(_ perMinute: Double) -> String {
            let m = Double(words.count) / perMinute
            return words.isEmpty ? "0" : m < 1 ? "\(max(1, Int(m * 60)))s" : "\(Int(m.rounded()))m"
        }
        let number = NumberFormatter()
        number.numberStyle = .decimal
        let n = { (value: Int) in number.string(from: NSNumber(value: value)) ?? String(value) }
        let values = [
            n(text.count), n(text.filter { !$0.isWhitespace && !$0.isNewline }.count), n(words.count), n(unique),
            n(text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }), n(sentences), n(paragraphs),
            n(text.utf8.count), minutes(230), minutes(150),
        ]
        for (tile, value) in zip(tiles, values) { tile.value = value }
        inputCard.setMeta("")
    }
}

// MARK: - Timestamps

final class TimePage: ToolPageController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let detected = ToolUI.caption("", size: 11)
    private let nowSeconds = NSTextField.label("", size: 20)
    private let nowDetail = ToolUI.caption("", size: 12)
    private var zones: [TimeZone] = []
    private lazy var zonePopup: ClosurePopUp = {
        let ids = ["UTC", "America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Berlin",
                   "Asia/Kolkata", "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney"]
        zones = [TimeZone.current] + ids.compactMap(TimeZone.init(identifier:)).filter { $0.identifier != TimeZone.current.identifier }
        let titles = zones.enumerated().map { i, zone in i == 0 ? "Local (\(zone.identifier))" : zone.identifier }
        let saved = zones.firstIndex { $0.identifier == value("zone") } ?? 0
        let popup = ClosurePopUp(titles, selected: saved)
        popup.onChange = { [weak self] index in
            guard let self else { return }
            self.store("zone", index == 0 ? "" : self.zones[index].identifier)
            self.update()
        }
        return popup
    }()
    private let rowTitles = ["Unix Seconds", "Unix Milliseconds", "ISO 8601 (UTC)", "ISO 8601 (Zone)", "RFC 2822",
                             "Readable", "Relative", "Calendar"]
    private lazy var rows = rowTitles.map { ValueRow(title: $0, titleWidth: 140) }
    private var timer: Timer?

    init() { super.init(toolId: "time") }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    override func loadView() {
        nowSeconds.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        nowDetail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let nowLabel = ToolUI.caption("NOW", size: 11)
        nowLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let copyNow = copyButton { String(Int(Date().timeIntervalSince1970)) }
        let useNow = ToolActionButton(title: "Use Now", symbol: "clock.arrow.circlepath", tip: "Convert the current time",
                                      style: .prominent) { [weak self] in
            guard let self else { return }
            self.field.stringValue = String(Int(Date().timeIntervalSince1970))
            self.update()
        }
        let nowRow = ToolUI.row([nowLabel, nowSeconds, nowDetail, ToolUI.spacer(), copyNow, useNow], spacing: 12)
        nowRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        nowRow.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let nowCard = ToolCard(title: nil, content: nowRow, footer: false)

        field.placeholderString = "Unix timestamp (s, ms, µs), ISO 8601, or a date like 2026-10-01 14:30"
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.controlSize = .large
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        zonePopup.controlSize = .large
        let inputRow = ToolUI.row([field, zonePopup], spacing: 10)
        let results = ToolCard(title: "Click a row to copy", content: ScrollStack(rows), footer: false)
        results.setContentHuggingPriority(.init(1), for: .vertical)
        view = ToolUI.page([nowCard, inputRow, detected, results], spacing: 10)

        field.stringValue = value("text") ?? ""
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        update()
    }

    override func focus() { view.window?.makeFirstResponder(field) }
    override var primaryOutput: String? { rows[2].value }

    func controlTextDidChange(_ obj: Notification) { update() }

    private var zone: TimeZone { zones[max(0, zonePopup.indexOfSelectedItem)] }

    private func tick() {
        guard view.window != nil else { return }
        let now = Date()
        nowSeconds.stringValue = String(Int(now.timeIntervalSince1970))
        nowDetail.stringValue = "\(Int64(now.timeIntervalSince1970 * 1000)) ms · \(iso(now, zone: zone, fractional: false))"
    }

    private func iso(_ date: Date, zone: TimeZone, fractional: Bool) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.string(from: date)
    }

    private func parse(_ raw: String) -> (Date, String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased() == "now" { return (Date(), "Now") }
        if let number = Double(s) {
            let digits = s.split(separator: ".")[0].filter(\.isNumber).count
            if digits >= 16 { return (Date(timeIntervalSince1970: number / 1_000_000), "Unix microseconds") }
            if digits >= 12 { return (Date(timeIntervalSince1970: number / 1000), "Unix milliseconds") }
            return (Date(timeIntervalSince1970: number), "Unix seconds")
        }
        let isoFormatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            isoFormatter.formatOptions = options
            if let d = isoFormatter.date(from: s) { return (d, "ISO 8601") }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = zone
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd", "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
                       "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE MMM dd HH:mm:ss zzz yyyy", "dd MMM yyyy"] {
            df.dateFormat = format
            if let d = df.date(from: s) { return (d, "Date (\(format), \(zone.identifier))") }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), let d = match.date {
            return (d, "Natural language")
        }
        return nil
    }

    private func update() {
        store("text", field.stringValue)
        guard !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            detected.stringValue = "Enter a timestamp or a date, or use Now."
            detected.textColor = .secondaryLabelColor
            rows.forEach { $0.value = "" }
            return
        }
        guard let parsed = parse(field.stringValue) else {
            detected.stringValue = "⚠︎ Couldn't read that as a timestamp or date"
            detected.textColor = .systemRed
            rows.forEach { $0.value = "" }
            return
        }
        let (date, kind) = parsed
        detected.stringValue = "Read as \(kind)"
        detected.textColor = .secondaryLabelColor
        let fractional = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = zone
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let readable = DateFormatter()
        readable.timeZone = zone
        readable.dateStyle = .full
        readable.timeStyle = .long
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let week = calendar.component(.weekOfYear, from: date)
        let quarter = (calendar.component(.month, from: date) - 1) / 3 + 1
        let values = [
            String(Int(date.timeIntervalSince1970.rounded(.down))),
            String(Int64((date.timeIntervalSince1970 * 1000).rounded())),
            iso(date, zone: TimeZone(identifier: "UTC")!, fractional: fractional),
            iso(date, zone: zone, fractional: fractional),
            rfc.string(from: date),
            readable.string(from: date),
            RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()),
            "Week \(week) · Day \(day) · Q\(quarter)",
        ]
        for (row, value) in zip(rows, values) { row.value = value }
    }
}

// MARK: - Generators

final class GeneratorPage: ToolPageController {
    private let uuids = CardTextView(editable: false)
    private lazy var uuidCard = ToolCard.text("UUIDs (v4)", uuids, actions: [
        newScratchButton { [weak self] in self?.uuids.string ?? "" },
        copyButton(prominent: true, title: "Copy All") { [weak self] in self?.uuids.string ?? "" },
    ])
    private lazy var count = StepperField(value: Int(value("count") ?? "") ?? 5, range: 1...500)
    private let random = ValueRow(title: "Value", titleWidth: 50)
    private let entropy = ToolUI.caption("", size: 11)
    private lazy var length = StepperField(value: Int(value("length") ?? "") ?? 24, range: 4...256)

    init() { super.init(toolId: "generate") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let regenerateUUIDs: () -> Void = { [weak self] in self?.generateUUIDs() }
        count.onChange = { [weak self] value in
            self?.store("count", String(value))
            self?.generateUUIDs()
        }
        let uuidRow = ToolUI.row([
            ToolUI.caption("Count"), count,
            chip("Uppercase", key: "upper", changed: regenerateUUIDs),
            chip("No Hyphens", key: "noHyphens", changed: regenerateUUIDs),
            chip("Braces", key: "braces", tip: "{…} like Windows GUIDs", changed: regenerateUUIDs),
            ToolUI.spacer(),
            ToolActionButton(title: "Generate", symbol: "arrow.clockwise", tip: "New UUIDs", style: .prominent, action: regenerateUUIDs),
        ])
        uuidCard.setContentHuggingPriority(.init(1), for: .vertical)

        let regenerateRandom: () -> Void = { [weak self] in self?.generateRandom() }
        length.onChange = { [weak self] value in
            self?.store("length", String(value))
            self?.generateRandom()
        }
        let randomRow = ToolUI.row([
            ToolUI.caption("Length"), length,
            chip("A–Z", key: "upperSet", default: true, changed: regenerateRandom),
            chip("a–z", key: "lowerSet", default: true, changed: regenerateRandom),
            chip("0–9", key: "digitSet", default: true, changed: regenerateRandom),
            chip("Symbols", key: "symbolSet", changed: regenerateRandom),
            chip("No Look-alikes", key: "unambiguous", tip: "Leave out 0 O o 1 l I", changed: regenerateRandom),
            ToolUI.spacer(),
            ToolActionButton(title: "Generate", symbol: "arrow.clockwise", tip: "New random string", style: .prominent,
                             action: regenerateRandom),
        ])
        let randomBody = NSStackView(views: [random, entropy])
        randomBody.orientation = .vertical
        randomBody.alignment = .leading
        randomBody.spacing = 2
        randomBody.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 8, right: 6)
        random.translatesAutoresizingMaskIntoConstraints = false
        random.widthAnchor.constraint(equalTo: randomBody.widthAnchor, constant: -12).isActive = true
        entropy.translatesAutoresizingMaskIntoConstraints = false
        entropy.lineBreakMode = .byTruncatingTail
        entropy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        entropy.leadingAnchor.constraint(equalTo: randomBody.leadingAnchor, constant: 16).isActive = true
        entropy.trailingAnchor.constraint(lessThanOrEqualTo: randomBody.trailingAnchor, constant: -16).isActive = true
        let randomCard = ToolCard(title: "Random String", content: randomBody, footer: false)

        view = ToolUI.page([uuidRow, uuidCard, randomRow, randomCard], spacing: 10)
        (view as? NSStackView)?.setCustomSpacing(22, after: uuidCard)
        generateUUIDs()
        generateRandom()
    }

    override var primaryOutput: String? { uuids.string }

    private func generateUUIDs() {
        let upper = flag("upper"), plain = flag("noHyphens"), braces = flag("braces")
        uuids.string = (0..<count.value).map { _ in
            var id = UUID().uuidString
            if !upper { id = id.lowercased() }
            if plain { id = id.replacingOccurrences(of: "-", with: "") }
            return braces ? "{\(id)}" : id
        }.joined(separator: "\n")
        uuidCard.setMeta("\(count.value) generated")
    }

    private func generateRandom() {
        var alphabet = ""
        if flag("upperSet", default: true) { alphabet += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        if flag("lowerSet", default: true) { alphabet += "abcdefghijklmnopqrstuvwxyz" }
        if flag("digitSet", default: true) { alphabet += "0123456789" }
        if flag("symbolSet") { alphabet += "!@#$%^&*()-_=+[]{};:,.<>?/~" }
        if flag("unambiguous") { alphabet.removeAll { "0Oo1lI".contains($0) } }
        let characters = Array(alphabet)
        guard !characters.isEmpty else {
            random.value = ""
            entropy.stringValue = "Pick at least one character set"
            return
        }
        var generator = SystemRandomNumberGenerator()
        random.value = String((0..<length.value).map { _ in characters.randomElement(using: &generator)! })
        let bits = Double(length.value) * log2(Double(characters.count))
        entropy.stringValue = "≈ \(Int(bits)) bits of entropy · \(characters.count) possible characters · click to copy"
    }
}
