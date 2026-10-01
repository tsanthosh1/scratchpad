import CryptoKit
import Foundation

struct TransformError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Text operations offered in the action palette. They apply to every selection, or to the whole
/// document when nothing is selected.
struct TextTransform {
    enum Kind {
        /// Replaces each selection with the result.
        case map((String) throws -> String)
        /// Inserts generated text at every caret.
        case insert(() -> String)
        /// Reports something about the text without changing it.
        case info((String) -> String)
    }

    let id: String
    let title: String
    let category: String
    let kind: Kind
    var keywords: String = ""
}

enum Transforms {
    static let all: [TextTransform] = encoding + hashing + caseChanges + lines + text + time
    static let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    // MARK: Encoding

    static let encoding: [TextTransform] = [
        .init(id: "base64Encode", title: "Base64 Encode", category: "Encode", kind: .map { Data($0.utf8).base64EncodedString() }),
        .init(id: "base64Decode", title: "Base64 Decode", category: "Decode", kind: .map(base64Decode)),
        .init(id: "base64UrlEncode", title: "Base64URL Encode", category: "Encode", kind: .map {
            Data($0.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }),
        .init(id: "urlEncode", title: "URL Encode (component)", category: "Encode", kind: .map { s in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }, keywords: "percent uri"),
        .init(id: "urlDecode", title: "URL Decode", category: "Decode", kind: .map { s in
            guard let decoded = s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw TransformError("Not valid percent-encoded text")
            }
            return decoded
        }, keywords: "percent uri"),
        .init(id: "htmlEscape", title: "HTML Escape", category: "Encode", kind: .map(htmlEscape), keywords: "entities xml"),
        .init(id: "htmlUnescape", title: "HTML Unescape", category: "Decode", kind: .map(htmlUnescape), keywords: "entities xml"),
        .init(id: "jsonEscape", title: "Escape as JSON / Java String", category: "Encode", kind: .map(jsonEscape), keywords: "quote string literal"),
        .init(id: "jsonUnescape", title: "Unescape JSON / Java String", category: "Decode", kind: .map(jsonUnescape), keywords: "string literal"),
        .init(id: "unicodeEscape", title: "Unicode Escape (\\uXXXX)", category: "Encode", kind: .map(unicodeEscape)),
        .init(id: "unicodeUnescape", title: "Unicode Unescape (\\uXXXX)", category: "Decode", kind: .map(unicodeUnescape)),
        .init(id: "hexEncode", title: "Hex Encode (UTF-8)", category: "Encode", kind: .map {
            Data($0.utf8).map { String(format: "%02x", $0) }.joined()
        }),
        .init(id: "hexDecode", title: "Hex Decode", category: "Decode", kind: .map(hexDecode)),
        .init(id: "jwtDecode", title: "Decode JWT", category: "Decode", kind: .map(jwtDecode), keywords: "token jws bearer"),
    ]

    // MARK: Hashing

    static let hashing: [TextTransform] = [
        .init(id: "md5", title: "MD5 Hash", category: "Hash", kind: .map { hex(Insecure.MD5.hash(data: Data($0.utf8))) }),
        .init(id: "sha1", title: "SHA-1 Hash", category: "Hash", kind: .map { hex(Insecure.SHA1.hash(data: Data($0.utf8))) }),
        .init(id: "sha256", title: "SHA-256 Hash", category: "Hash", kind: .map { hex(SHA256.hash(data: Data($0.utf8))) }),
        .init(id: "sha512", title: "SHA-512 Hash", category: "Hash", kind: .map { hex(SHA512.hash(data: Data($0.utf8))) }),
    ]

    // MARK: Case

    static let caseChanges: [TextTransform] = [
        .init(id: "upper", title: "UPPER CASE", category: "Case", kind: .map { $0.uppercased() }),
        .init(id: "lower", title: "lower case", category: "Case", kind: .map { $0.lowercased() }),
        .init(id: "title", title: "Title Case", category: "Case", kind: .map { $0.capitalized }),
        .init(id: "sentence", title: "Sentence case", category: "Case", kind: .map { s in
            let lower = s.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }),
        .init(id: "camel", title: "camelCase", category: "Case", kind: .map(perLine { w in
            w.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }.joined()
        })),
        .init(id: "pascal", title: "PascalCase", category: "Case", kind: .map(perLine { $0.map(\.capitalized).joined() })),
        .init(id: "snake", title: "snake_case", category: "Case", kind: .map(perLine { $0.map { $0.lowercased() }.joined(separator: "_") })),
        .init(id: "constant", title: "CONSTANT_CASE", category: "Case", kind: .map(perLine { $0.map { $0.uppercased() }.joined(separator: "_") })),
        .init(id: "kebab", title: "kebab-case", category: "Case", kind: .map(perLine { $0.map { $0.lowercased() }.joined(separator: "-") })),
        .init(id: "dot", title: "dot.case", category: "Case", kind: .map(perLine { $0.map { $0.lowercased() }.joined(separator: ".") })),
    ]

    // MARK: Lines

    static let lines: [TextTransform] = [
        .init(id: "sortAsc", title: "Sort Lines (A → Z)", category: "Lines", kind: .map(lineOp {
            $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        })),
        .init(id: "sortDesc", title: "Sort Lines (Z → A)", category: "Lines", kind: .map(lineOp {
            $0.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        })),
        .init(id: "sortLength", title: "Sort Lines by Length", category: "Lines", kind: .map(lineOp { $0.sorted { $0.count < $1.count } })),
        .init(id: "reverseLines", title: "Reverse Lines", category: "Lines", kind: .map(lineOp { $0.reversed() })),
        .init(id: "shuffleLines", title: "Shuffle Lines", category: "Lines", kind: .map(lineOp { $0.shuffled() })),
        .init(id: "uniqueLines", title: "Remove Duplicate Lines", category: "Lines", kind: .map(lineOp { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }), keywords: "unique distinct dedupe"),
        .init(id: "removeEmpty", title: "Remove Empty Lines", category: "Lines", kind: .map(lineOp {
            $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }), keywords: "blank"),
        .init(id: "trimLines", title: "Trim Whitespace on Each Line", category: "Lines", kind: .map(lineOp {
            $0.map { $0.trimmingCharacters(in: .whitespaces) }
        })),
        .init(id: "joinSpace", title: "Join Lines (space)", category: "Lines", kind: .map { s in
            splitLines(s).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        }),
        .init(id: "joinComma", title: "Join Lines with Comma", category: "Lines", kind: .map { s in
            splitLines(s).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }, keywords: "csv"),
        .init(id: "quoteJoin", title: "Quote Lines & Join with Comma", category: "Lines", kind: .map { s in
            splitLines(s).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
        }, keywords: "sql in list"),
        .init(id: "splitComma", title: "Split Comma-Separated to Lines", category: "Lines", kind: .map { s in
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        }, keywords: "csv"),
        .init(id: "numberLines", title: "Number Lines", category: "Lines", kind: .map(lineOp { lines in
            lines.enumerated().map { "\($0.offset + 1). \($0.element)" }
        })),
    ]

    // MARK: Text

    static let text: [TextTransform] = [
        .init(id: "trim", title: "Trim Whitespace", category: "Text", kind: .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
        .init(id: "collapseSpaces", title: "Collapse Whitespace", category: "Text", kind: .map { s in
            s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        }),
        .init(id: "reverse", title: "Reverse Text", category: "Text", kind: .map { String($0.reversed()) }),
        .init(id: "count", title: "Count Characters, Words & Lines", category: "Text", kind: .info { s in
            let words = s.split { $0.isWhitespace || $0.isNewline }.count
            return "\(s.count) characters · \(words) words · \(splitLines(s).count) lines · \(s.utf8.count) bytes"
        }, keywords: "length stats"),
    ]

    // MARK: Time & generators

    static let time: [TextTransform] = [
        .init(id: "epochToIso", title: "Unix Timestamp → ISO Date", category: "Time", kind: .map(epochToIso), keywords: "epoch millis date"),
        .init(id: "isoToEpoch", title: "ISO Date → Unix Timestamp", category: "Time", kind: .map(isoToEpoch), keywords: "epoch date"),
        .init(id: "insertEpoch", title: "Insert Current Unix Timestamp", category: "Insert", kind: .insert {
            String(Int(Date().timeIntervalSince1970))
        }, keywords: "epoch now"),
        .init(id: "insertEpochMillis", title: "Insert Current Timestamp (ms)", category: "Insert", kind: .insert {
            String(Int64(Date().timeIntervalSince1970 * 1000))
        }, keywords: "epoch millis now"),
        .init(id: "insertIso", title: "Insert Current ISO Date", category: "Insert", kind: .insert {
            isoFormatter(fractional: false).string(from: Date())
        }, keywords: "now date time"),
        .init(id: "insertUuid", title: "Insert UUID", category: "Insert", kind: .insert { UUID().uuidString.lowercased() }, keywords: "guid"),
    ]

    // MARK: Implementations

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64Data(_ raw: String) throws -> Data {
        var s = raw.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { throw TransformError("Not valid Base64") }
        return data
    }

    private static func base64Decode(_ raw: String) throws -> String {
        let data = try base64Data(raw)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransformError("Decoded \(data.count) bytes that aren't UTF-8 text")
        }
        return text
    }

    private static func hexDecode(_ raw: String) throws -> String {
        let cleaned = raw.replacingOccurrences(of: #"(0x|\s|:)"#, with: "", options: .regularExpression)
        guard cleaned.count % 2 == 0 else { throw TransformError("Hex text must have an even number of digits") }
        var bytes = [UInt8]()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { throw TransformError("Not valid hex") }
            bytes.append(byte)
            index = next
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw TransformError("Decoded bytes aren't UTF-8 text") }
        return text
    }

    private static let htmlEntities: [(String, String)] = [
        ("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&#39;"),
    ]

    private static func htmlEscape(_ s: String) -> String {
        htmlEntities.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func htmlUnescape(_ s: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                     "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–"]
        let regex = try! NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#\\d+|[a-zA-Z]+);")
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String($0) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(UnicodeScalar.init).map { String($0) }
            } else {
                replacement = named[body]
            }
            result += replacement ?? ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        return result + ns.substring(from: last)
    }

    private static func jsonEscape(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let quoted = data.flatMap { String(data: $0, encoding: .utf8) } ?? s
        return String(quoted.dropFirst().dropLast())
    }

    private static func jsonUnescape(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 ? trimmed : "\"\(raw)\""
        guard let data = quoted.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            throw TransformError("Not a valid escaped string")
        }
        return value
    }

    private static func unicodeEscape(_ s: String) -> String {
        s.unicodeScalars.map { scalar -> String in
            if scalar.isASCII { return String(scalar) }
            return String(scalar).utf16.map { String(format: "\\u%04x", $0) }.joined()
        }.joined()
    }

    private static func unicodeUnescape(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?:\\u[0-9a-fA-F]{4})+"#)
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let units = ns.substring(with: m.range).components(separatedBy: "\\u").dropFirst().compactMap { UInt16($0, radix: 16) }
            result += String(utf16CodeUnits: units, count: units.count)
            last = NSMaxRange(m.range)
        }
        return result + ns.substring(from: last)
    }

    private static func jwtDecode(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[Bb]earer\s+"#, with: "", options: .regularExpression)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw TransformError("A JWT has three dot-separated parts") }
        func pretty(_ part: Substring) throws -> String {
            let data = try base64Data(String(part))
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: out, encoding: .utf8) else {
                throw TransformError("JWT part isn't JSON")
            }
            return text
        }
        var result = "// header\n\(try pretty(parts[0]))\n// payload\n\(try pretty(parts[1]))"
        if let data = try? base64Data(String(parts[1])),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for claim in ["iat", "nbf", "exp"] {
                if let seconds = payload[claim] as? Double {
                    result += "\n// \(claim): \(isoFormatter(fractional: false).string(from: Date(timeIntervalSince1970: seconds)))"
                }
            }
        }
        return result
    }

    private static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    private static func epochToIso(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(s) else { throw TransformError("Not a number") }
        // Heuristic: 13+ digits are milliseconds, 16+ microseconds.
        let digits = s.split(separator: ".")[0].filter(\.isNumber).count
        let seconds = digits >= 16 ? value / 1_000_000 : digits >= 12 ? value / 1000 : value
        return isoFormatter(fractional: digits >= 12).string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func isoToEpoch(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = isoFormatter(fractional: true).date(from: s) ?? isoFormatter(fractional: false).date(from: s) {
            return String(Int(date.timeIntervalSince1970))
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            df.dateFormat = format
            if let date = df.date(from: s) { return String(Int(date.timeIntervalSince1970)) }
        }
        throw TransformError("Unrecognised date format")
    }

    // MARK: Helpers

    static func splitLines(_ s: String) -> [String] {
        s.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Applies a whole-list line operation, keeping a trailing newline if there was one.
    private static func lineOp(_ op: @escaping ([String]) -> [String]) -> (String) -> String {
        { s in
            let trailing = s.hasSuffix("\n")
            var lines = splitLines(s)
            if trailing { lines.removeLast() }
            return op(lines).joined(separator: "\n") + (trailing ? "\n" : "")
        }
    }

    /// Splits each line into words (on separators and camelCase humps) and rejoins it.
    private static func perLine(_ join: @escaping ([String]) -> String) -> (String) -> String {
        { s in
            splitLines(s).map { line in
                let leading = String(line.prefix { $0 == " " || $0 == "\t" })
                let spaced = line
                    .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
                    .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
                let words = spaced.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                return words.isEmpty ? line : leading + join(words)
            }.joined(separator: "\n")
        }
    }
}
