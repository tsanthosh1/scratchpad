import Foundation

/// IntelliJ "Go to File"-style matching: query characters appear in order in the name, preferring word starts
/// and camel humps ("apcl" → api-client.http, "FIS" → FindInScratches.swift) and consecutive runs.
/// "folder/name" also matches the folder, and a trailing ":line" is ignored here (the caller jumps to it).
enum FuzzyMatcher {
    /// "notes.md:42" → ("notes.md", 42). A colon without a number is kept as part of the name.
    static func splitLine(_ query: String) -> (name: String, line: Int?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return (trimmed, nil) }
        let suffix = trimmed[trimmed.index(after: colon)...]
        guard suffix.isEmpty || suffix.allSatisfy(\.isNumber) else { return (trimmed, nil) }
        return (String(trimmed[..<colon]), Int(suffix))
    }

    /// Scores `name` (and, for queries with "/", its `folder`) against the query. Positions index `name`'s characters.
    static func match(query: String, name: String, folder: String) -> (score: Int, positions: [Int])? {
        let query = query.filter { $0 != "*" && $0 != " " }
        if query.isEmpty { return (1, []) }
        if let slash = query.lastIndex(of: "/") {
            let folderQuery = String(query[..<slash])
            let nameQuery = String(query[query.index(after: slash)...])
            var folderScore = 0
            if !folderQuery.isEmpty {
                guard let folderMatch = subsequence(folderQuery, in: folder) else { return nil }
                folderScore = folderMatch.score
            }
            if nameQuery.isEmpty { return (folderScore + 1, []) }
            guard let nameMatch = subsequence(nameQuery, in: name) else { return nil }
            return (nameMatch.score + folderScore / 2, nameMatch.positions)
        }
        if let nameMatch = subsequence(query, in: name) {
            var score = nameMatch.score
            let lowerName = name.lowercased(), lowerQuery = query.lowercased()
            let stem = (lowerName as NSString).deletingPathExtension
            if lowerName == lowerQuery || stem == lowerQuery { score += 1000 }
            else if lowerName.hasPrefix(lowerQuery) { score += 200 }
            return (score - name.count / 4, nameMatch.positions)
        }
        // "notesapi" can still find api/notes.md through its folder.
        guard !folder.isEmpty, let pathMatch = subsequence(query, in: folder + "/" + name) else { return nil }
        let offset = folder.count + 1
        return (pathMatch.score - 50, pathMatch.positions.filter { $0 >= offset }.map { $0 - offset })
    }

    /// Best in-order placement of the query's characters in `candidate` (dynamic programming over positions).
    static func subsequence(_ query: String, in candidate: String) -> (score: Int, positions: [Int])? {
        let q = Array(query), c = Array(candidate)
        guard !q.isEmpty, q.count <= c.count, c.count <= 400 else { return q.isEmpty ? (0, []) : nil }
        let lowerQ = q.map { Character($0.lowercased()) }, lowerC = c.map { Character($0.lowercased()) }

        func isBoundary(_ i: Int) -> Bool {
            if i == 0 { return true }
            let previous = c[i - 1], current = c[i]
            if !(previous.isLetter || previous.isNumber) { return true }
            if current.isUppercase && previous.isLowercase { return true }
            return current.isNumber != previous.isNumber
        }
        let boundary = (0..<c.count).map(isBoundary)
        let humps = q.contains(where: \.isLowercase) && q.contains(where: \.isUppercase)

        let none = Int.min / 4
        // best[i][j]: best score with query[i] placed at candidate[j]; from[i][j]: where query[i-1] was placed.
        var best = Array(repeating: Array(repeating: none, count: c.count), count: q.count)
        var from = Array(repeating: Array(repeating: -1, count: c.count), count: q.count)
        for i in 0..<q.count {
            for j in i..<c.count where lowerC[j] == lowerQ[i] {
                // In a mixed-case query an uppercase letter means "a hump": it must land on a word boundary.
                if humps && q[i].isUppercase && i > 0 && !boundary[j] { continue }
                var gain = 1
                if boundary[j] { gain += 9 }
                if j == 0 { gain += 6 }
                if q[i] == c[j] { gain += 1 }
                if i == 0 {
                    best[i][j] = gain - (boundary[j] ? 0 : min(j, 6))
                    continue
                }
                for k in (i - 1)..<j where best[i - 1][k] > none {
                    let gap = j - k - 1
                    var score = best[i - 1][k] + gain
                    if gap == 0 { score += 6 } else { score -= boundary[j] ? min(gap, 12) / 4 : min(gap, 6) }
                    if score > best[i][j] { best[i][j] = score; from[i][j] = k }
                }
            }
        }
        let last = q.count - 1
        guard let end = (0..<c.count).max(by: { best[last][$0] < best[last][$1] }), best[last][end] > none else { return nil }
        var positions = [end]
        var i = last, j = end
        while i > 0 { j = from[i][j]; i -= 1; positions.insert(j, at: 0) }
        return (best[last][end], positions)
    }
}
