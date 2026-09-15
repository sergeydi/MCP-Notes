import SwiftUI

struct NoteListItemView: View {
    let note: NoteMetadata
    var score: Float? = nil
    var searchQuery: String? = nil
    var searchSnippet: SnippetBuilder.Match? = nil
    var isSelected: Bool = false

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

            if let searchSnippet {
                Text(attributedSnippet(searchSnippet))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? .white : .primary)
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

    private func attributedSnippet(_ snippet: SnippetBuilder.Match) -> AttributedString {
        var result = AttributedString(snippet.before)
        var highlighted = AttributedString(snippet.match)
        highlighted.font = Font.subheadline.bold()
        highlighted.foregroundColor = isSelected ? Color.white : Color.primary
        result += highlighted
        result += AttributedString(snippet.after)
        return result
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
