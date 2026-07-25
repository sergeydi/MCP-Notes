import Foundation

/// Parses and serializes the YAML frontmatter block in note files.
///
/// Expected format:
/// ```
/// ---
/// uid: <UUID>
/// tags: [tag1, tag2]
/// ---
///
/// Markdown body…
/// ```
public struct FrontmatterParser {
    public struct ParseResult {
        public let uid: UUID
        public let tags: [String]
        public let bookmarked: Bool
        public let body: String
    }

    public init() {}

    /// Returns `nil` if the content has no valid frontmatter block.
    public static func parse(_ content: String) -> ParseResult? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        let frontmatterLines: [String]
        let body: String
        if let end = closingIndex {
            frontmatterLines = Array(lines[1..<end])
            // `serialize` always inserts exactly one blank line between the closing
            // `---` and the body. Strip only that single separator line here so parse
            // is a true inverse of serialize — trimming *all* leading/trailing
            // newlines would silently drop blank lines the user intentionally typed
            // at the start/end of the body on the next external-change reload.
            var bodyLines = Array(lines[(end + 1)...])
            if bodyLines.first == "" {
                bodyLines.removeFirst()
            }
            body = bodyLines.joined(separator: "\n")
        } else {
            // No closing ---: treat entire remainder as frontmatter, body is empty.
            frontmatterLines = Array(lines[1...])
            body = ""
        }

        var uid: UUID?
        var tags: [String] = []
        var bookmarked = false
        var parsingBlockTags = false

        for line in frontmatterLines {
            if line.hasPrefix("uid:") {
                parsingBlockTags = false
                let value = line.dropFirst("uid:".count).trimmingCharacters(in: .whitespaces)
                uid = UUID(uuidString: String(value))
            } else if line.hasPrefix("tags:") {
                parsingBlockTags = false
                let value = line.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    parsingBlockTags = true
                } else {
                    tags = parseInlineArray(String(value))
                }
            } else if line.hasPrefix("bookmarked:") {
                parsingBlockTags = false
                let value = line.dropFirst("bookmarked:".count).trimmingCharacters(in: .whitespaces)
                bookmarked = value == "true"
            } else if parsingBlockTags {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    let tag = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { tags.append(tag) }
                } else if !trimmed.isEmpty {
                    parsingBlockTags = false
                }
            }
        }

        guard let uid else { return nil }
        return ParseResult(uid: uid, tags: tags, bookmarked: bookmarked, body: body)
    }

    public static func serialize(uid: UUID, tags: [String], isBookmarked: Bool = false, body: String) -> String {
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

    // Parses `[a, b, c]` inline YAML array syntax.
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
