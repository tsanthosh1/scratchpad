import Foundation

enum Language: String, CaseIterable {
    // Order drives the "New Scratch" picker (first nine get number keys) and the language menus.
    case json, xml, html, markdown, richtext, http, diff, csv, javascript, typescript, java, python, shell
    case css, sql, yaml, openapi, toml, properties, kotlin, go, rust, cpp, tsv, text

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .markdown: return "Markdown"
        case .richtext: return "Rich Text"
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .http: return "HTTP"
        case .diff: return "Diff"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .java: return "Java"
        case .python: return "Python"
        case .shell: return "Shell"
        case .css: return "CSS"
        case .sql: return "SQL"
        case .yaml: return "YAML"
        case .openapi: return "OpenAPI / Swagger"
        case .toml: return "TOML"
        case .properties: return "Properties"
        case .kotlin: return "Kotlin"
        case .go: return "Go"
        case .rust: return "Rust"
        case .cpp: return "C / C++"
        case .text: return "Plain Text"
        }
    }

    /// First entry is the extension used when creating or converting a scratch.
    var fileExtensions: [String] {
        switch self {
        case .json: return ["json", "jsonc", "json5"]
        case .xml: return ["xml", "xsd", "xsl", "wsdl", "plist", "svg", "pom"]
        case .html: return ["html", "htm", "xhtml"]
        case .markdown: return ["md", "markdown", "mdown"]
        case .richtext: return ["rtfd", "rtf"]
        case .csv: return ["csv"]
        case .tsv: return ["tsv", "tab"]
        case .http: return ["http", "rest"]
        case .diff: return ["diff"]
        case .javascript: return ["js", "mjs", "cjs", "jsx"]
        case .typescript: return ["ts", "mts", "cts", "tsx"]
        case .java: return ["java"]
        case .python: return ["py"]
        case .shell: return ["sh", "bash", "zsh"]
        case .css: return ["css", "scss", "less"]
        case .sql: return ["sql"]
        case .yaml: return ["yaml", "yml"]
        // Two-part extensions keep specs valid YAML/JSON for other tools while marking them as OpenAPI here.
        case .openapi: return ["openapi.yaml", "openapi.yml", "openapi.json", "swagger.yaml", "swagger.yml", "swagger.json"]
        case .toml: return ["toml"]
        case .properties: return ["properties", "env", "ini", "conf", "cfg"]
        case .kotlin: return ["kt", "kts"]
        case .go: return ["go"]
        case .rust: return ["rs"]
        case .cpp: return ["cpp", "cc", "cxx", "c", "h", "hpp"]
        case .text: return ["txt", "log"]
        }
    }

    var fileExtension: String { fileExtensions[0] }

    var canFormat: Bool {
        switch self {
        case .json, .xml, .html, .markdown, .http, .diff, .javascript, .typescript, .java, .css, .sql, .yaml, .openapi: return true
        default: return false
        }
    }

    var canCompact: Bool { self == .json || self == .xml }
    var canRun: Bool { [.javascript, .typescript, .java, .python, .shell, .http].contains(self) }
    /// Edited in the native rich text page instead of the code editor.
    var isRichText: Bool { self == .richtext }
    var isTable: Bool { self == .csv || self == .tsv }

    var symbolName: String {
        switch self {
        case .json: return "curlybraces"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .html: return "globe"
        case .markdown: return "doc.richtext"
        case .richtext: return "textformat"
        case .csv, .tsv: return "tablecells"
        case .http: return "network"
        case .diff: return "arrow.left.arrow.right.square"
        case .javascript: return "j.square"
        case .typescript: return "t.square"
        case .java: return "cup.and.saucer"
        case .python: return "p.square"
        case .shell: return "terminal"
        case .css: return "paintbrush"
        case .sql: return "cylinder"
        case .yaml: return "list.bullet.indent"
        case .openapi: return "point.3.connected.trianglepath.dotted"
        case .toml: return "list.bullet.rectangle"
        case .properties: return "slider.horizontal.3"
        case .kotlin: return "k.square"
        case .go: return "g.square"
        case .rust: return "r.square"
        case .cpp: return "c.square"
        case .text: return "doc.plaintext"
        }
    }

    init(fileExtension ext: String) {
        let lower = ext.lowercased()
        self = Language.allCases.first { $0.fileExtensions.contains(lower) } ?? .text
    }

    /// The language of a file name, including two-part extensions such as `api.openapi.yaml`.
    init(fileName name: String) {
        let lower = name.lowercased()
        if Language.openapi.fileExtensions.contains(where: { lower.hasSuffix("." + $0) }) {
            self = .openapi
        } else {
            self = Language(fileExtension: (name as NSString).pathExtension)
        }
    }

    /// A file name without its (possibly two-part) extension: "api.openapi.yaml" → "api".
    static func stem(of name: String) -> String {
        let lower = name.lowercased()
        if let ext = Language.openapi.fileExtensions.first(where: { lower.hasSuffix("." + $0) }) {
            return String(name.dropLast(ext.count + 1))
        }
        return (name as NSString).deletingPathExtension
    }

    /// Detection reads at most this much of the text, so pasting megabytes never stalls the app.
    private static let sampleLines = 400
    private static let sampleLineLength = 1000
    private static let sampleCharacters = 64_000
    /// Larger JSON isn't parsed in full; it's recognised by its first character.
    private static let maxJSONParse = 3_000_000

    /// The first lines of `text` (each cut to `sampleLineLength`), without leading blank space.
    static func sample(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        var out = ""
        var lines = 0
        var index = start
        while index < text.endIndex, lines < sampleLines, out.count < sampleCharacters {
            let end = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
            out += text[index..<end].prefix(sampleLineLength)
            out += "\n"
            lines += 1
            index = end < text.endIndex ? text.index(after: end) : end
        }
        while out.last?.isWhitespace == true { out.removeLast() }
        return out
    }

    /// Best-effort guess used when pasting into an empty scratch or creating one from the clipboard.
    static func detect(_ raw: String) -> Language {
        let text = sample(raw)
        guard let first = text.first else { return .text }
        func has(_ pattern: String, _ options: NSString.CompareOptions = []) -> Bool {
            text.range(of: pattern, options: options.union(.regularExpression)) != nil
        }

        if first == "{" || first == "[" {
            let spec = first == "{" && has(#""(openapi|swagger)"\s*:\s*"\d"#)
            if raw.utf8.count > maxJSONParse { return spec ? .openapi : .json }
            if let data = raw.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return spec ? .openapi : .json
            }
        }
        if has(#"(?m)^["']?(openapi|swagger)["']?\s*:\s*["']?\d"#) { return .openapi }
        if first == "<" {
            let lower = text.prefix(2000).lowercased()
            let htmlMarkers = ["<!doctype html", "<html", "<head", "<body", "<div", "<span", "<p>", "<p ",
                               "<script", "<style", "<a ", "<table", "<ul", "<br", "<meta", "<link"]
            if htmlMarkers.contains(where: lower.contains) { return .html }
            return .xml
        }
        if DiffFile.isDiff(text) { return .diff }
        if Curl.looksLikeCurl(text)
            || has(#"(?m)\A(\s*(#|//).*\n)*\s*(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(https?://|\{\{)\S+"#) {
            return .http
        }
        if text.hasPrefix("#!") {
            if has(#"^#!.*python"#) { return .python }
            if has(#"^#!.*node"#) { return .javascript }
            return .shell
        }
        if has(#"\b(public\s+)?(final\s+)?(class|record|interface|enum)\s+\w+"#),
           text.contains("static void main") || text.contains("System.out.")
            || has(#"^\s*(package|import)\s+[\w.]+(\.\*)?;"#, .anchored) {
            return .java
        }
        if has(#"(?im)^\s*(select\s.+\sfrom\s|insert\s+into\s|update\s+\w+\s+set\s|create\s+(table|index|view)\s|delete\s+from\s|with\s+\w+\s+as\s*\()"#) {
            return .sql
        }
        if has(#"(?m)^\s*(def\s+\w+\(.*\)\s*:|from\s+[\w.]+\s+import\s|import\s+\w+\s*$|if\s+__name__\s*==)"#)
            || has(#"(?m)^\s*print\(.*\)\s*$"#) && !text.contains(";") {
            return .python
        }
        if has(#"(?m)^\s*(interface|type)\s+\w+\s*(=|\{)|:\s*(string|number|boolean)\b"#) { return .typescript }
        let jsHints = [#"\b(const|let|var)\s+\w+\s*="#, #"\bfunction\s*\w*\s*\("#, #"=>"#,
                       #"console\.\w+\("#, #"\brequire\(['"]"#, #"(?m)^\s*import\s.+\sfrom\s"#]
        if jsHints.contains(where: { has($0) }) { return .javascript }
        if let table = detectTable(text) { return table }
        if has(#"(?m)^(#{1,6}\s+\S|```|\s*[-*]\s+\[[ xX]\]\s|\[[^\]]+\]\([^)]+\))"#) { return .markdown }
        if has(#"(?m)^\[[\w.\-]+\]\s*$"#) && has(#"(?m)^\w[\w\-]*\s*=\s*\S"#) { return .toml }
        if text.hasPrefix("---") || has(#"(?m)^[\w\-]+:\s+\S.*$\n^[\w\-]+:(\s|$)"#) { return .yaml }
        if has(#"(?m)^\s*[\w.\-]+\s*[=:]\s*\S"#) && !has(#"[{};]"#) && has(#"(?m)^[\w.\-]+="#) { return .properties }
        if has(#"(?m)^[ \t]*[.#]?[\w\-][\w\-.#:>+~,*()\[\]="' \t]*\{[ \t]*$"#) && has(#"[\w\-]+[ \t]*:[^;\n]+;"#) { return .css }
        if first == "{" || first == "[" { return .json }
        return .text
    }

    /// Rows of delimiter-separated values: at least two lines that split into the same number (≥ 2) of fields.
    static func detectTable(_ text: String) -> Language? {
        let lines = text.split(whereSeparator: \.isNewline).prefix(200).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        for (delimiter, language) in [("\t", Language.tsv), (",", .csv), (";", .csv), ("|", .csv)] {
            let counts = lines.map { CSV.fieldCount(String($0), delimiter: Character(delimiter)) }
            guard let firstCount = counts.first, firstCount >= 2 else { continue }
            // Two lines of prose with one comma each aren't a table.
            if delimiter != "\t", firstCount < 3, lines.count < 3 { continue }
            let consistent = counts.filter { $0 == firstCount }.count
            guard Double(consistent) >= Double(counts.count) * 0.9 else { continue }
            // Indented code uses tabs too; real TSV rarely starts a line with one.
            if delimiter == "\t", lines.contains(where: { $0.hasPrefix("\t") }) { continue }
            if delimiter != "\t", lines.contains(where: { $0.contains("{") || $0.hasSuffix(";") }) { continue }
            return language
        }
        return nil
    }
}

/// Just enough CSV parsing for detection: quoted fields may contain the delimiter.
enum CSV {
    static func fieldCount(_ line: String, delimiter: Character) -> Int {
        var count = 1, quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == delimiter, !quoted { count += 1 }
        }
        return count
    }
}
