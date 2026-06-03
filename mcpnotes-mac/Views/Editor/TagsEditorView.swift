import SwiftUI

struct TagsEditorView: View {
    @Binding var tags: [String]
    let allTags: [String]
    var onChange: () -> Void

    @State private var newTagText = ""
    @FocusState private var isInputFocused: Bool
    @State private var highlightedIndex: Int? = nil
    @State private var textFieldHeight: CGFloat = 22

    private var suggestions: [String] {
        let existing = Set(tags)
        let q = newTagText.lowercased()
        return allTags.filter {
            !existing.contains($0) &&
            !q.isEmpty &&
            $0.lowercased().hasPrefix(q)
        }
    }

    private var showSuggestions: Bool {
        isInputFocused && !suggestions.isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                tagCapsule(tag)
            }

            TextField("Add tag…", text: $newTagText)
                .textFieldStyle(.plain)
                .frame(minWidth: 60)
                .focused($isInputFocused)
                .onChange(of: newTagText) { highlightedIndex = nil }
                .onSubmit { commitNewTag() }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlightedIndex = ((highlightedIndex ?? -1) + 1) % suggestions.count
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    let count = suggestions.count
                    highlightedIndex = ((highlightedIndex ?? count) - 1 + count) % count
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let idx = highlightedIndex, idx < suggestions.count else { return .ignored }
                    selectSuggestion(suggestions[idx])
                    return .handled
                }
                .accessibilityLabel("New tag name")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    textFieldHeight = $0
                }
                .overlay(alignment: .topLeading) {
                    if showSuggestions {
                        suggestionsDropdown
                            .offset(y: textFieldHeight + 2)
                    }
                }
                .zIndex(10)
        }
    }

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                Button {
                    selectSuggestion(suggestion)
                } label: {
                    Text(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            highlightedIndex == index ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { highlightedIndex = index }
                }
            }
        }
        .frame(minWidth: 150)
        .padding(.vertical, 4)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
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

    private func selectSuggestion(_ suggestion: String) {
        addTag(suggestion)
        newTagText = ""
        highlightedIndex = nil
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
