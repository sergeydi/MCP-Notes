import SwiftUI

struct NoteListItemView: View {
    let note: Note
    var score: Float? = nil
    var searchQuery: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.filename)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let score {
                    Spacer()
                    Text(String(format: "%.0f%%", score * 100))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formattedDate)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                if !note.tags.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        tagsRow(count: note.tags.count, truncated: false)
                        ForEach(Array(stride(from: note.tags.count - 1, through: 0, by: -1)), id: \.self) { count in
                            tagsRow(count: count, truncated: true)
                        }
                    }
                }
            }

            if let snippet = bodySnippet {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !note.body.isEmpty {
                Text(bodyPreview)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private func tagsRow(count: Int, truncated: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(note.tags.prefix(count), id: \.self) { tag in
                tagCapsule(tag)
            }
            if truncated {
                Text("…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tagCapsule(_ tag: String) -> some View {
        Text(tag)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.2), in: Capsule())
    }

    private var bodySnippet: AttributedString? {
        guard let query = searchQuery, !query.isEmpty else { return nil }
        let stripped = MarkdownPatterns.stripMarkdown(note.body)
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

        var result = AttributedString(before)
        var highlighted = AttributedString(match)
        highlighted.font = Font.subheadline.bold()
        highlighted.foregroundColor = Color.primary
        result += highlighted
        result += AttributedString(after)
        return result
    }

    private var bodyPreview: String {
        MarkdownPatterns.stripMarkdown(note.body)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var formattedDate: String {
        note.modifiedAt.formatted(date: .long, time: .omitted)
    }

    private var accessibilityDescription: String {
        if note.tags.isEmpty {
            return note.filename
        }
        return String(localized: "\(note.filename), tags: \(note.tags.joined(separator: ", "))")
    }
}
