import SwiftUI

struct TagsEditorView: View {
    @Binding var tags: [String]
    let allTags: [String]
    var onChange: () -> Void

    @State private var newTagText = ""
    @FocusState private var isInputFocused: Bool

    private var suggestions: [String] {
        let existing = Set(tags)
        let q = newTagText.lowercased()
        return allTags.filter {
            !existing.contains($0) &&
            (q.isEmpty || $0.lowercased().hasPrefix(q))
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                tagCapsule(tag)
            }

            HStack(spacing: 0) {
                TextField("Add tag…", text: $newTagText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 60)
                    .focused($isInputFocused)
                    .onSubmit { commitNewTag() }
                    .accessibilityLabel("New tag name")

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { addTag(suggestion) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func tagCapsule(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag)
            Button {
                removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.15), in: Capsule())
    }

    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        onChange()
    }

    private func commitNewTag() {
        addTag(newTagText)
        newTagText = ""
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        onChange()
    }
}
