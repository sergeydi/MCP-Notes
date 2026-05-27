import SwiftUI

struct NoteListItemView: View {
    let note: Note
    var score: Float? = nil

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
                    .font(.subheadline)
                if !note.tags.isEmpty {
                    ForEach(note.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }
            }

            if !note.body.isEmpty {
                Text(bodyPreview)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.visible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var bodyPreview: String {
        NoteIndexer.stripMarkdown(note.body)
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
        return "\(note.filename), tags: \(note.tags.joined(separator: ", "))"
    }
}
