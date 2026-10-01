import Foundation

struct HTTPRequest {
    var name: String?
    var method: String
    var url: String
    var headers: [(name: String, value: String)] = []
    var body: String?
    /// UTF-16 range of the request's `###` block in the source document.
    var range = NSRange(location: 0, length: 0)
    /// UTF-16 offset of the request line (`GET https://…`).
    var lineOffset = 0

    var title: String { name ?? "\(method) \(url)" }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `GET base` plus one indented `?first` / `&next` line per query parameter.
    static func structuredRequestLine(method: String, url: String, indent: String = "    ") -> [String] {
        guard let q = url.firstIndex(of: "?") else { return ["\(method) \(url)"] }
        var query = String(url[url.index(after: q)...])
        var fragment = ""
        if let hash = query.firstIndex(of: "#") {
            fragment = String(query[hash...])
            query = String(query[..<hash])
        }
        var params = query.split(separator: "&", omittingEmptySubsequences: true).map(String.init)
        guard !params.isEmpty else { return ["\(method) \(url)"] }
        params[params.count - 1] += fragment
        return ["\(method) \(url[..<q])"] + params.enumerated().map { "\(indent)\($0.offset == 0 ? "?" : "&")\($0.element)" }
    }

    /// Serialises the request in `.http` syntax.
    var httpText: String {
        var lines: [String] = []
        if let name { lines.append("### \(name)") }
        lines += Self.structuredRequestLine(method: method, url: url)
        lines += headers.map { "\($0.name): \($0.value)" }
        if let body, !body.isEmpty { lines += ["", body] }
        return lines.joined(separator: "\n")
    }
}

struct HTTPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// IntelliJ-style HTTP request files: requests separated by `###` lines, each made of a request line,
/// headers, a blank line and an optional body. `@name = value` defines a variable used as `{{name}}`.
struct HTTPFile {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT"]

    static let template = """
    ### Example GET
    GET https://httpbin.org/get?hello=world
    Accept: application/json

    ### Example POST with a variable
    @baseUrl = https://httpbin.org

    POST {{baseUrl}}/post
    Content-Type: application/json

    {
      "id": "{{$uuid}}",
      "createdAt": "{{$isoTimestamp}}"
    }

    """

    var variables: [String: String] = [:]
    var requests: [HTTPRequest] = []

    /// The request whose block contains `offset`, or the only request in the file.
    func request(at offset: Int) -> HTTPRequest? {
        if let hit = requests.first(where: { NSLocationInRange(offset, $0.range) }) { return hit }
        if let last = requests.last, offset >= NSMaxRange(last.range) { return last }
        return requests.count == 1 ? requests[0] : nil
    }

    static func parse(_ text: String) -> HTTPFile {
        var file = HTTPFile()
        let ns = text as NSString
        var lines: [(text: String, range: NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, _, enclosing, _ in
            lines.append((line ?? "", enclosing))
        }

        enum Phase { case preamble, headers, body }
        var phase = Phase.preamble
        var request: HTTPRequest?
        var name: String?
        var bodyLines: [String] = []
        var blockStart = 0
        var blockEnd = 0

        func finishBlock() {
            if var r = request {
                while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeLast() }
                r.body = bodyLines.isEmpty ? nil : bodyLines.joined(separator: "\n")
                r.name = name
                r.range = NSRange(location: blockStart, length: blockEnd - blockStart)
                file.requests.append(r)
            }
            request = nil
            name = nil
            bodyLines = []
            phase = .preamble
        }

        for (line, range) in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("###") {
                finishBlock()
                blockStart = range.location
                blockEnd = NSMaxRange(range)
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                name = title.isEmpty ? nil : title
                continue
            }
            blockEnd = NSMaxRange(range)

            switch phase {
            case .preamble:
                if trimmed.isEmpty { continue }
                if let comment = commentText(trimmed) {
                    if let tag = comment.range(of: #"^@name\s+"#, options: .regularExpression) {
                        name = String(comment[tag.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    continue
                }
                if let (key, value) = variableDefinition(trimmed) {
                    file.variables[key] = value
                    continue
                }
                request = requestLine(trimmed)
                request?.lineOffset = range.location
                phase = .headers
            case .headers:
                if trimmed.isEmpty {
                    phase = .body
                } else if commentText(trimmed) != nil {
                    continue
                } else if let first = line.first, first == " " || first == "\t",
                          let c = trimmed.first, "?&/".contains(c) {
                    request?.url += trimmed
                } else if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    request?.headers.append((key, value))
                }
            case .body:
                bodyLines.append(line)
            }
        }
        finishBlock()
        return file
    }

    private static func commentText(_ line: String) -> String? {
        if line.hasPrefix("//") { return line.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("#") { return line.dropFirst(1).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private static func variableDefinition(_ line: String) -> (String, String)? {
        guard line.hasPrefix("@"),
              let match = line.range(of: #"^@([A-Za-z_][\w.\-]*)\s*=\s*"#, options: .regularExpression) else { return nil }
        let key = line[line.index(after: line.startIndex)..<match.upperBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: "= \t"))
        return (key, String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    private static func requestLine(_ line: String) -> HTTPRequest {
        var parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var method = "GET"
        if let first = parts.first, methods.contains(first.uppercased()), parts.count > 1 {
            method = first.uppercased()
            parts.removeFirst()
        }
        if parts.count > 1, parts.last?.uppercased().hasPrefix("HTTP/") == true { parts.removeLast() }
        return HTTPRequest(method: method, url: parts.joined(separator: " "))
    }

    // MARK: Variables

    /// Substitutes `{{variables}}` in the URL, headers and body.
    func resolve(_ request: HTTPRequest) throws -> HTTPRequest {
        var r = request
        r.url = try substitute(r.url)
        r.headers = try r.headers.map { ($0.name, try substitute($0.value)) }
        if let body = r.body { r.body = try substitute(body) }
        if !r.url.contains("://") { r.url = "http://" + r.url }
        return r
    }

    func substitute(_ text: String, depth: Int = 0) throws -> String {
        guard text.contains("{{") else { return text }
        let regex = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            if let value = Self.dynamicValue(name) {
                out += value
            } else if let value = variables[name] {
                guard depth < 10 else { throw HTTPError("Variable {{\(name)}} refers to itself") }
                out += try substitute(value, depth: depth + 1)
            } else {
                throw HTTPError("Unknown variable {{\(name)}}. Define it with @\(name) = value")
            }
            last = NSMaxRange(match.range)
        }
        out += ns.substring(from: last)
        return out
    }

    static let dynamicVariables = ["$uuid", "$timestamp", "$isoTimestamp", "$randomInt", "$processEnv.NAME"]

    private static func dynamicValue(_ name: String) -> String? {
        switch name {
        case "$uuid", "$random.uuid": return UUID().uuidString.lowercased()
        case "$timestamp": return String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp": return ISO8601DateFormatter().string(from: Date())
        case "$randomInt": return String(Int.random(in: 0..<1000))
        default:
            if name.hasPrefix("$processEnv.") {
                return ProcessInfo.processInfo.environment[String(name.dropFirst("$processEnv.".count))] ?? ""
            }
            return nil
        }
    }
}

/// Re-indents JSON without reordering keys (JSONSerialization would sort or shuffle them).
enum JSONPretty {
    static func format(_ text: String, indent: Int = 2) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var level = 0, inString = false, escaped = false, i = 0
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }
        func newline() {
            out.append("\n")
            for _ in 0..<(level * indent) { out.append(" ") }
        }
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                var j = i + 1
                while j < s.count, isSpace(s[j]) { j += 1 }
                if j < s.count, (c == "{" && s[j] == "}") || (c == "[" && s[j] == "]") {
                    out.append(c); out.append(s[j])
                    i = j + 1
                    continue
                }
                out.append(c)
                level += 1
                newline()
            case "}", "]":
                level -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(":"); out.append(" ")
            default:
                if !isSpace(c) { out.append(c) }
            }
            i += 1
        }
        return String(out)
    }
}
