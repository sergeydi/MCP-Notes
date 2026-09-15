import Foundation

/// Builds a highlighted-context snippet around a search match inside a note's body.
///
/// Pure string logic (no SwiftUI dependency) so it can run wherever a note's full body is
/// transiently available — e.g. `NoteStore.searchNoteBodies`, where body is read from disk
/// one note at a time and discarded right after this call.
public struct SnippetBuilder {
    public struct Match: Sendable {
        public let before: String
        public let match: String
        public let after: String
    }

    /// Strips markdown from `text`, locates the first case-insensitive occurrence of `query`,
    /// and returns up to ~120 stripped characters of context around it (±40 chars before the
    /// match). Returns `nil` if `query` doesn't occur in the stripped text.
    public static func match(in text: String, query: String) -> Match? {
        guard !query.isEmpty else { return nil }
        let stripped = MarkdownPatterns.stripMarkdown(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let lowerStripped = stripped.lowercased()
        let lowerQuery = query.lowercased()
        guard let matchRange = lowerStripped.range(of: lowerQuery) else { return nil }

        let matchOffset = lowerStripped.distance(from: lowerStripped.startIndex, to: matchRange.lowerBound)
        let matchLength = lowerQuery.count
        let startOffset = max(0, matchOffset - 40)
        let endOffset = min(stripped.count, startOffset + 120)

        let startIndex = stripped.index(stripped.startIndex, offsetBy: startOffset)
        let matchStart = stripped.index(stripped.startIndex, offsetBy: matchOffset)
        let matchEnd = stripped.index(matchStart, offsetBy: matchLength)
        let endIndex = stripped.index(stripped.startIndex, offsetBy: endOffset)

        let before = (startOffset > 0 ? "…" : "") + String(stripped[startIndex..<matchStart])
        let match = String(stripped[matchStart..<matchEnd])
        let after = String(stripped[matchEnd..<endIndex]) + (endOffset < stripped.count ? "…" : "")
        return Match(before: before, match: match, after: after)
    }
}
