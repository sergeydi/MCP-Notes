import Foundation

/// Pure string algorithms for list editing behaviour: continuation prefix and renumbering.
public struct MarkdownListContinuation {
    /// Returns `(prefixLength, continuationPrefix)` for a list line, or `nil` if not a list item.
    public static func info(for line: String) -> (prefixLength: Int, continuation: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = String(line.prefix(line.count - trimmed.count))

        for marker in ["- [ ] ", "- [x] ", "- [X] "] {
            if trimmed.hasPrefix(marker) { return (indent.count + marker.count, indent + "- [ ] ") }
        }
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) { return (indent.count + marker.count, indent + marker) }
        }
        var digits = ""
        var rest = String(trimmed)
        while let ch = rest.first, ch.isNumber { digits.append(ch); rest = String(rest.dropFirst()) }
        if !digits.isEmpty, rest.hasPrefix(". "), let n = Int(digits) {
            return (indent.count + digits.count + 2, indent + "\(n + 1). ")
        }
        return nil
    }

    /// Returns `(range, replacement)` pairs for numbered list items that are out of sequence.
    /// Apply in reverse order to preserve range validity.
    public static func renumberingReplacements(in string: String) -> [(NSRange, String)] {
        let nsStr = string as NSString
        let length = nsStr.length
        var pos = 0
        var replacements: [(NSRange, String)] = []
        var contexts: [String: Int] = [:]

        while pos < length {
            let lineRange = nsStr.lineRange(for: NSRange(location: pos, length: 0))
            let line = nsStr.substring(with: lineRange)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(line.prefix(line.count - trimmed.count))
            var digits = ""
            var rest = String(trimmed)
            while let ch = rest.first, ch.isNumber { digits.append(ch); rest = String(rest.dropFirst()) }

            if !digits.isEmpty, rest.hasPrefix(". "), let n = Int(digits) {
                if let expected = contexts[indent] {
                    if n != expected {
                        let oldLen = indent.count + digits.count + 2
                        replacements.append((NSRange(location: lineRange.location, length: oldLen), indent + "\(expected). "))
                    }
                    contexts[indent] = expected + 1
                } else {
                    contexts[indent] = n + 1
                }
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contexts.removeAll()
            }
            pos = NSMaxRange(lineRange)
        }

        return replacements
    }
}
