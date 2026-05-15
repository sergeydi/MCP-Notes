import Foundation

// Duplicated from the main app target (same logic, no shared framework).
struct FrontmatterParser {
    struct ParseResult {
        let uid: UUID
        let tags: [String]
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
        let bodyLines = lines[(end + 1)...]
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .init(charactersIn: "\n"))

        var uid: UUID?
        var tags: [String] = []

        for line in frontmatterLines {
            if line.hasPrefix("uid:") {
                let value = line.dropFirst("uid:".count).trimmingCharacters(in: .whitespaces)
                uid = UUID(uuidString: String(value))
            } else if line.hasPrefix("tags:") {
                let value = line.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                tags = parseInlineArray(String(value))
            }
        }

        guard let uid else { return nil }
        return ParseResult(uid: uid, tags: tags, body: body)
    }

    static func serialize(uid: UUID, tags: [String], body: String) -> String {
        let tagList = tags.isEmpty ? "[]" : "[" + tags.joined(separator: ", ") + "]"
        return """
        ---
        uid: \(uid.uuidString)
        tags: \(tagList)
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
