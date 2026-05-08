import SwiftUI

struct NoteListItemView: View {
    let note: Note
    var score: Float? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.filename)
                    .font(.body)
                    .lineLimit(1)
                if let score {
                    Spacer()
                    Text(String(format: "%.0f%%", score * 100))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        if note.tags.isEmpty {
            return note.filename
        }
        return "\(note.filename), tags: \(note.tags.joined(separator: ", "))"
    }
}
