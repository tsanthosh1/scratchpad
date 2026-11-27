import AppKit

/// A dev tool: one page with its own layout, listed in the sidebar's Dev Tools folder.
struct DevTool {
    let id: String
    let title: String
    let symbol: String
    let tint: NSColor
    let summary: String
    var keywords = ""
    let makePage: () -> ToolPageController
}

enum DevTools {
    static let all: [DevTool] = [
        .init(id: "base64", title: "Base64", symbol: "textformat.abc", tint: .systemBlue,
              summary: "Encode and decode text or files", keywords: "b64 encode decode", makePage: Base64Page.init),
        .init(id: "url", title: "URL Encoding", symbol: "link", tint: .systemTeal,
              summary: "Percent-encoding and URL parts", keywords: "percent uri query encode decode", makePage: URLPage.init),
        .init(id: "html", title: "HTML Entities", symbol: "chevron.left.forwardslash.chevron.right", tint: .systemOrange,
              summary: "Escape and unescape HTML", keywords: "xml entity escape", makePage: HTMLPage.init),
        .init(id: "escape", title: "String Escaping", symbol: "quote.bubble", tint: .systemPurple,
              summary: "JSON / Java strings and \\u escapes", keywords: "json java literal quote unicode", makePage: EscapePage.init),
        .init(id: "hex", title: "Hex", symbol: "number", tint: .systemIndigo,
              summary: "UTF-8 text to hex and back", keywords: "hexadecimal bytes", makePage: HexPage.init),
        .init(id: "jwt", title: "JWT Decoder", symbol: "key.fill", tint: .systemPink,
              summary: "Claims, expiry and signature check", keywords: "token bearer jws", makePage: JWTPage.init),
        .init(id: "hash", title: "Hash", symbol: "lock.shield", tint: .systemGreen,
              summary: "MD5, SHA and HMAC digests", keywords: "digest checksum sha256 md5 hmac", makePage: HashPage.init),
        .init(id: "case", title: "Case Converter", symbol: "textformat", tint: .systemBrown,
              summary: "camelCase, snake_case, kebab-case…", keywords: "camel snake kebab upper lower title", makePage: CasePage.init),
        .init(id: "lines", title: "Line Tools", symbol: "list.bullet", tint: .systemCyan,
              summary: "Clean, dedupe, sort and join lists", keywords: "sort unique dedupe join split csv sql", makePage: LinesPage.init),
        .init(id: "text", title: "Text Statistics", symbol: "text.alignleft", tint: .systemGray,
              summary: "Characters, words, lines, reading time", keywords: "count length words characters", makePage: TextStatsPage.init),
        .init(id: "time", title: "Timestamps", symbol: "clock", tint: .systemRed,
              summary: "Unix epoch ↔ dates in any zone", keywords: "epoch unix date time millis iso", makePage: TimePage.init),
        .init(id: "generate", title: "Generators", symbol: "wand.and.stars", tint: .systemYellow,
              summary: "UUIDs and random strings", keywords: "uuid guid random password", makePage: GeneratorPage.init),
        .init(id: "mcp", title: "MCP Tester", symbol: "network", tint: .systemIndigo,
              summary: "Test MCP servers, validate connection and list tools",
              keywords: "mcp model context protocol server test tools npx stdio sse rpc remote claude",
              makePage: MCPTesterPage.init),
    ]

    static let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
