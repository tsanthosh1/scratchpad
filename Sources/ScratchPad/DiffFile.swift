import Foundation

/// A diff scratch keeps both sides in one readable file:
///
///     --- left: Original
///     …left text…
///     --- right: Modified
///     …right text…
///
/// Content lines that look like a side header are prefixed with a backslash.
/// The editor (web/src/diffdoc.js) owns reading and writing; this mirrors the format for native use.
enum DiffFile {
    static let template = serialize(leftName: "Original", left: "", rightName: "Modified", right: "")

    static func isDiff(_ text: String) -> Bool {
        text.hasPrefix("--- left:") || text.hasPrefix("--- syntax:")
    }

    static func serialize(leftName: String, left: String, rightName: String, right: String, syntax: Language? = nil) -> String {
        var out = syntax.map { "--- syntax: \($0.rawValue)\n" } ?? ""
        out += "--- left: \(leftName)\n\(escape(left))\n--- right: \(rightName)\n\(escape(right))"
        return out
    }

    private static func escape(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.range(of: #"^\\*--- (left|right|syntax):"#, options: .regularExpression) != nil ? "\\" + line : line
        }.joined(separator: "\n")
    }
}
