import Foundation

/// Converts between curl command lines and `HTTPRequest`s.
enum Curl {
    static func looksLikeCurl(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^curl(\.exe)?\s"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Converts one or more curl commands to `.http` text (multiple requests are separated by `###`).
    static func toHTTP(_ text: String, indent: Int = 2) throws -> String {
        let commands = try tokenize(text).filter { $0.first?.lowercased().hasPrefix("curl") == true }
        guard !commands.isEmpty else { throw HTTPError("No curl command found") }
        return try commands.map { args -> String in
            var request = try parse(arguments: Array(args.dropFirst()))
            if let body = request.body, request.header("Content-Type")?.contains("json") == true,
               let pretty = JSONPretty.format(body, indent: indent) {
                request.body = pretty
            }
            return request.httpText
        }.joined(separator: "\n\n###\n")
    }

    // MARK: Import

    private static let shortOptions: [Character: String] = [
        "X": "request", "H": "header", "d": "data", "u": "user", "b": "cookie", "A": "user-agent", "e": "referer",
        "F": "form", "G": "get", "I": "head", "o": "output", "m": "max-time", "w": "write-out", "x": "proxy",
        "T": "upload-file", "E": "cert", "D": "dump-header", "r": "range", "c": "cookie-jar", "K": "config",
        "U": "proxy-user", "Y": "speed-limit", "y": "speed-time", "z": "time-cond", "s": "silent", "S": "show-error",
        "L": "location", "k": "insecure", "i": "include", "v": "verbose", "f": "fail", "g": "globoff",
        "N": "no-buffer", "O": "remote-name", "J": "remote-header-name", "q": "disable", "4": "ipv4", "6": "ipv6",
        "#": "progress-bar",
    ]

    private static let optionsWithValue: Set<String> = [
        "request", "header", "data", "data-raw", "data-binary", "data-ascii", "data-urlencode", "json", "user", "cookie",
        "user-agent", "referer", "form", "form-string", "output", "max-time", "connect-timeout", "write-out", "proxy",
        "upload-file", "cert", "key", "cacert", "capath", "cert-type", "dump-header", "range", "cookie-jar", "config",
        "proxy-user", "speed-limit", "speed-time", "time-cond", "url", "retry", "retry-delay", "retry-max-time",
        "resolve", "interface", "limit-rate", "max-redirs", "oauth2-bearer", "aws-sigv4", "unix-socket",
        "dns-servers", "connect-to", "request-target", "variable", "expand-url",
    ]

    static func parse(_ command: String) throws -> HTTPRequest {
        guard let args = try tokenize(command).first(where: { $0.first?.lowercased().hasPrefix("curl") == true }) else {
            throw HTTPError("No curl command found")
        }
        return try parse(arguments: Array(args.dropFirst()))
    }

    private static func parse(arguments args: [String]) throws -> HTTPRequest {
        var options: [(name: String, value: String?)] = []
        var positional: [String] = []
        var i = 0
        var endOfOptions = false
        func next() throws -> String {
            i += 1
            guard i < args.count else { throw HTTPError("Missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            if endOfOptions || !arg.hasPrefix("-") || arg == "-" {
                positional.append(arg)
            } else if arg == "--" {
                endOfOptions = true
            } else if arg.hasPrefix("--") {
                var name = String(arg.dropFirst(2))
                var value: String?
                if let eq = name.firstIndex(of: "="), optionsWithValue.contains(String(name[..<eq])) {
                    value = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                } else if optionsWithValue.contains(name) {
                    value = try next()
                }
                options.append((name, value))
            } else {
                // Short options can be clustered (-sSL) and take attached values (-XPOST).
                var chars = Substring(arg.dropFirst())
                while let c = chars.first {
                    chars = chars.dropFirst()
                    let name = shortOptions[c] ?? String(c)
                    if optionsWithValue.contains(name) {
                        options.append((name, chars.isEmpty ? try next() : String(chars)))
                        break
                    }
                    options.append((name, nil))
                }
            }
            i += 1
        }

        var method: String?
        var url = positional.first
        var headers: [(name: String, value: String)] = []
        var data: [String] = []
        var form: [(name: String, value: String, isFile: Bool, extras: [String: String])] = []
        var get = false, head = false, json = false
        var uploadFile: String?

        func addHeader(_ name: String, _ value: String) {
            if let index = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                headers[index].value = value
            } else {
                headers.append((name, value))
            }
        }

        for (name, value) in options {
            let v = value ?? ""
            switch name {
            case "request": method = v.uppercased()
            case "url": url = v
            case "header":
                guard let colon = v.firstIndex(of: ":") else { continue }
                let key = v[..<colon].trimmingCharacters(in: .whitespaces)
                let val = v[v.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !val.isEmpty { headers.append((key, val)) }
            case "data", "data-ascii", "data-binary":
                data.append(v.hasPrefix("@") && v != "@-" ? "< \(v.dropFirst())" : v)
            case "data-raw": data.append(v)
            case "json":
                data.append(v.hasPrefix("@") ? "< \(v.dropFirst())" : v)
                json = true
            case "data-urlencode": data.append(urlEncodedData(v))
            case "form", "form-string": form.append(formField(v, literal: name == "form-string"))
            case "get": get = true
            case "head": head = true
            case "user":
                let credentials = Data(v.utf8).base64EncodedString()
                addHeader("Authorization", "Basic \(credentials)")
            case "oauth2-bearer": addHeader("Authorization", "Bearer \(v)")
            case "cookie": if v.contains("=") { addHeader("Cookie", v) }
            case "user-agent": addHeader("User-Agent", v)
            case "referer": addHeader("Referer", v)
            case "upload-file": uploadFile = v
            default: break
            }
        }

        guard var target = url, !target.isEmpty else { throw HTTPError("The curl command has no URL") }
        if !target.contains("://") { target = "http://" + target }

        var body: String?
        if get {
            if !data.isEmpty { target += (target.contains("?") ? "&" : "?") + data.joined(separator: "&") }
        } else if !form.isEmpty {
            let boundary = "WebAppBoundary"
            headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            headers.append(("Content-Type", "multipart/form-data; boundary=\(boundary)"))
            var lines: [String] = []
            for field in form {
                lines.append("--\(boundary)")
                var disposition = "Content-Disposition: form-data; name=\"\(field.name)\""
                if field.isFile {
                    let filename = field.extras["filename"] ?? (field.value as NSString).lastPathComponent
                    disposition += "; filename=\"\(filename)\""
                }
                lines.append(disposition)
                if let type = field.extras["type"] { lines.append("Content-Type: \(type)") }
                lines.append("")
                lines.append(field.isFile ? "< \(field.value)" : field.value)
            }
            lines.append("--\(boundary)--")
            body = lines.joined(separator: "\n")
        } else if !data.isEmpty {
            body = data.joined(separator: json ? "" : "&")
            if json {
                if headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                    headers.append(("Content-Type", "application/json"))
                }
                if headers.first(where: { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }) == nil {
                    headers.append(("Accept", "application/json"))
                }
            } else if headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                let looksLikeJSON = body.map { JSONPretty.format($0) != nil && ($0.hasPrefix("{") || $0.hasPrefix("[")) } ?? false
                headers.append(("Content-Type", looksLikeJSON ? "application/json" : "application/x-www-form-urlencoded"))
            }
        } else if let uploadFile {
            body = "< \(uploadFile)"
        }

        let resolvedMethod = method
            ?? (head ? "HEAD" : get ? "GET" : body != nil ? (uploadFile != nil && data.isEmpty && form.isEmpty ? "PUT" : "POST") : "GET")
        return HTTPRequest(method: resolvedMethod, url: target, headers: headers, body: body)
    }

    /// `--data-urlencode` forms: `content`, `=content`, `name=content`, `@file`, `name@file`.
    private static func urlEncodedData(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ s: Substring) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(s) }
        if let eq = value.firstIndex(of: "=") {
            let name = value[..<eq]
            let content = value[value.index(after: eq)...]
            return name.isEmpty ? encode(content) : "\(name)=\(encode(content))"
        }
        if value.hasPrefix("@") || value.contains("@") { return value }
        return encode(Substring(value))
    }

    /// `-F name=value`, `-F name=@path;type=image/png;filename=x.png`, `-F name=<path`.
    private static func formField(_ spec: String, literal: Bool)
        -> (name: String, value: String, isFile: Bool, extras: [String: String]) {
        guard let eq = spec.firstIndex(of: "=") else { return (spec, "", false, [:]) }
        let name = String(spec[..<eq])
        var value = String(spec[spec.index(after: eq)...])
        if literal { return (name, value, false, [:]) }
        var extras: [String: String] = [:]
        let isFile = value.hasPrefix("@") || value.hasPrefix("<")
        if isFile {
            value.removeFirst()
            var parts = value.components(separatedBy: ";")
            value = parts.removeFirst()
            for part in parts {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { extras[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            }
        }
        return (name, value, isFile, extras)
    }

    // MARK: Shell tokenizer

    /// Splits shell text into commands (at newlines, `;`, `|`, `&&`) of words, handling quotes,
    /// `$'…'` strings and backslash line continuations.
    static func tokenize(_ text: String) throws -> [[String]] {
        let s = Array(text)
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var i = 0
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        while i < s.count {
            let c = s[i]
            switch c {
            case "\\":
                if i + 1 < s.count {
                    let n = s[i + 1]
                    if n == "\n" || n == "\r\n" { i += 2; continue }
                    word.append(n)
                    inWord = true
                }
                i += 2
            case "'":
                inWord = true
                i += 1
                while i < s.count, s[i] != "'" { word.append(s[i]); i += 1 }
                guard i < s.count else { throw HTTPError("Unterminated ' quote in curl command") }
                i += 1
            case "\"":
                inWord = true
                i += 1
                while i < s.count, s[i] != "\"" {
                    if s[i] == "\\", i + 1 < s.count, "\"\\$`\n".contains(s[i + 1]) {
                        if s[i + 1] != "\n" { word.append(s[i + 1]) }
                        i += 2
                    } else {
                        word.append(s[i])
                        i += 1
                    }
                }
                guard i < s.count else { throw HTTPError("Unterminated \" quote in curl command") }
                i += 1
            case "$" where i + 1 < s.count && s[i + 1] == "'":
                inWord = true
                i += 2
                while i < s.count, s[i] != "'" {
                    if s[i] == "\\", i + 1 < s.count {
                        let (decoded, consumed) = ansiEscape(s, from: i + 1)
                        word += decoded
                        i += 1 + consumed
                    } else {
                        word.append(s[i])
                        i += 1
                    }
                }
                guard i < s.count else { throw HTTPError("Unterminated $' quote in curl command") }
                i += 1
            case "^" where i + 1 < s.count && (s[i + 1] == "\n" || s[i + 1] == "\r\n"):
                // Windows cmd line continuation.
                i += 2
            case " ", "\t", "\r":
                endWord()
                i += 1
            case "\n", "\r\n", ";", "|":
                endCommand()
                i += 1
            case "&" where i + 1 < s.count && s[i + 1] == "&":
                endCommand()
                i += 2
            case "#" where !inWord:
                while i < s.count, s[i] != "\n" { i += 1 }
            default:
                word.append(c)
                inWord = true
                i += 1
            }
        }
        endCommand()
        return commands
    }

    private static func ansiEscape(_ s: [Character], from i: Int) -> (String, Int) {
        let c = s[i]
        switch c {
        case "n": return ("\n", 1)
        case "t": return ("\t", 1)
        case "r": return ("\r", 1)
        case "0": return ("\0", 1)
        case "e", "E": return ("\u{1B}", 1)
        case "x", "u", "U":
            let maxDigits = c == "x" ? 2 : c == "u" ? 4 : 8
            var digits = ""
            var j = i + 1
            while j < s.count, digits.count < maxDigits, s[j].isHexDigit { digits.append(s[j]); j += 1 }
            if let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) {
                return (String(Character(scalar)), 1 + digits.count)
            }
            return ("\\" + String(c), 1)
        default: return (String(c), 1)
        }
    }

    // MARK: Export

    /// A multi-line curl command for an already resolved request.
    static func export(_ request: HTTPRequest) -> String {
        var first = "curl"
        var options: [String] = []
        var headers = request.headers
        let body = request.body.flatMap { $0.isEmpty ? nil : $0 }

        var bodyOptions: [String] = []
        if let body {
            if let boundary = multipartBoundary(headers), let parts = multipartFields(body, boundary: boundary) {
                headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
                bodyOptions = parts.map { "-F \(quote($0))" }
            } else if let file = singleFileReference(body) {
                bodyOptions = ["--data-binary \(quote("@" + file))"]
            } else {
                bodyOptions = ["--data-raw \(quote(body))"]
            }
        }

        if request.method == "HEAD" && body == nil {
            first += " --head"
        } else if !(request.method == "GET" && body == nil) && !(request.method == "POST" && body != nil) {
            first += " -X \(request.method)"
        }
        first += " \(quote(request.url))"
        options += headers.map { "-H \(quote("\($0.name): \($0.value)"))" }
        options += bodyOptions
        return ([first] + options).joined(separator: " \\\n  ")
    }

    private static func quote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: #"^[A-Za-z0-9_\-./:@%+=,]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func singleFileReference(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("< "), !trimmed.contains("\n") else { return nil }
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func multipartBoundary(_ headers: [(name: String, value: String)]) -> String? {
        guard let type = headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value,
              type.lowercased().hasPrefix("multipart/form-data"),
              let range = type.range(of: "boundary=") else { return nil }
        return String(type[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" ;"))
    }

    /// Turns a multipart body back into `-F` arguments; nil when a part can't be expressed that way.
    private static func multipartFields(_ body: String, boundary: String) -> [String]? {
        var fields: [String] = []
        let chunks = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "--\(boundary)")
        for chunk in chunks.dropFirst() {
            if chunk.hasPrefix("--") { break }
            let part = chunk.hasPrefix("\n") ? String(chunk.dropFirst()) : chunk
            guard let split = part.range(of: "\n\n") else { return nil }
            let headerText = part[..<split.lowerBound]
            var content = String(part[split.upperBound...])
            if content.hasSuffix("\n") { content.removeLast() }
            guard let name = headerText.firstMatch(#"name="([^"]*)""#) else { return nil }
            let filename = headerText.firstMatch(#"filename="([^"]*)""#)
            let type = headerText.firstMatch(#"(?im)^Content-Type:\s*(.+)$"#)
            if let file = singleFileReference(content) {
                var spec = "\(name)=@\(file)"
                if let type { spec += ";type=\(type)" }
                if let filename, filename != (file as NSString).lastPathComponent { spec += ";filename=\(filename)" }
                fields.append(spec)
            } else {
                fields.append("\(name)=\(content)")
            }
        }
        return fields.isEmpty ? nil : fields
    }
}

private extension StringProtocol {
    func firstMatch(_ pattern: String) -> String? {
        let text = String(self)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
