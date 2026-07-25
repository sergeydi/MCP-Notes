import Foundation

// Duplicated from the main app target (same logic, no shared framework).
struct FrontmatterParser {
    struct ParseResult {
        let uid: UUID
        let tags: [String]
        let bookmarked: Bool
        let body: String
    }

    static func parse(_ content: String) -> ParseResult? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }
        guard let end = closingIndex else { return nil }

        let frontmatterLines = Array(lines[1..<end])
        // `serialize` always inserts exactly one blank line between the closing
        // `---` and the body. Strip only that single separator line here so parse
        // is a true inverse of serialize — trimming *all* leading/trailing
        // newlines would silently drop blank lines intentionally present in the body.
        var bodyLines = Array(lines[(end + 1)...])
        if bodyLines.first == "" {
            bodyLines.removeFirst()
        }
        let body = bodyLines.joined(separator: "\n")

        var uid: UUID?
        var tags: [String] = []
        var bookmarked = false

        for line in frontmatterLines {
            if line.hasPrefix("uid:") {
                let value = line.dropFirst("uid:".count).trimmingCharacters(in: .whitespaces)
                uid = UUID(uuidString: String(value))
            } else if line.hasPrefix("tags:") {
                let value = line.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                tags = parseInlineArray(String(value))
            } else if line.hasPrefix("bookmarked:") {
                let value = line.dropFirst("bookmarked:".count).trimmingCharacters(in: .whitespaces)
                bookmarked = value == "true"
            }
        }

        guard let uid else { return nil }
        return ParseResult(uid: uid, tags: tags, bookmarked: bookmarked, body: body)
    }

    static func serialize(uid: UUID, tags: [String], isBookmarked: Bool = false, body: String) -> String {
        let tagList = tags.isEmpty ? "[]" : "[" + tags.joined(separator: ", ") + "]"
        let bookmarkedLine = isBookmarked ? "\nbookmarked: true" : ""
        return """
        ---
        uid: \(uid.uuidString)
        tags: \(tagList)\(bookmarkedLine)
        ---

        \(body)
        """
    }

    private static func parseInlineArray(_ value: String) -> [String] {
        var s = value.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("["), s.hasSuffix("]") else { return [] }
        s = String(s.dropFirst().dropLast())
        guard !s.isEmpty else { return [] }
        return s.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
