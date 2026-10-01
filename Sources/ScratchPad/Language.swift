import Foundation

enum Language: String, CaseIterable {
    // Order drives the "New Scratch" picker (first nine get number keys) and the language menus.
    case json, xml, html, markdown, http, diff, javascript, typescript, java, python, shell
    case css, sql, yaml, toml, properties, kotlin, go, rust, cpp, text

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .markdown: return "Markdown"
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
        case .toml: return ["toml"]
        case .properties: return ["properties", "env", "ini", "conf", "cfg"]
        case .kotlin: return ["kt", "kts"]
        case .go: return ["go"]
        case .rust: return ["rs"]
        case .cpp: return ["cpp", "cc", "cxx", "c", "h", "hpp"]
        case .text: return ["txt", "log", "csv", "tsv"]
        }
    }

    var fileExtension: String { fileExtensions[0] }

    var canFormat: Bool {
        switch self {
        case .json, .xml, .html, .markdown, .http, .diff, .javascript, .typescript, .java, .css, .sql, .yaml: return true
        default: return false
        }
    }

    var canCompact: Bool { self == .json || self == .xml }
    var canRun: Bool { [.javascript, .typescript, .java, .python, .shell, .http].contains(self) }
    var canPreview: Bool { self == .markdown || self == .html }

    var symbolName: String {
        switch self {
        case .json: return "curlybraces"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .html: return "globe"
        case .markdown: return "doc.richtext"
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

    /// Best-effort guess used when pasting into an empty scratch or creating one from the clipboard.
    static func detect(_ raw: String) -> Language {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return .text }
        func has(_ pattern: String, _ options: NSString.CompareOptions = []) -> Bool {
            text.range(of: pattern, options: options.union(.regularExpression)) != nil
        }

        if first == "{" || first == "[" {
            if let data = text.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return .json
            }
        }
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
        if has(#"(?m)^(#{1,6}\s+\S|```|\s*[-*]\s+\[[ xX]\]\s|\[[^\]]+\]\([^)]+\))"#) { return .markdown }
        if has(#"(?m)^\[[\w.\-]+\]\s*$"#) && has(#"(?m)^\w[\w\-]*\s*=\s*\S"#) { return .toml }
        if text.hasPrefix("---") || has(#"(?m)^[\w\-]+:\s+\S.*$\n^[\w\-]+:(\s|$)"#) { return .yaml }
        if has(#"(?m)^\s*[\w.\-]+\s*[=:]\s*\S"#) && !has(#"[{};]"#) && has(#"(?m)^[\w.\-]+="#) { return .properties }
        if has(#"(?m)^\s*[.#]?[\w\-]+(\s*[,>+~]?\s*[.#]?[\w\-:]+)*\s*\{\s*$"#) && has(#"[\w\-]+\s*:\s*[^;]+;"#) { return .css }
        if first == "{" || first == "[" { return .json }
        return .text
    }
}
