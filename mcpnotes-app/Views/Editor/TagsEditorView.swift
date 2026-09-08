import SwiftUI

struct TagsEditorView: View {
    @Binding var tags: [String]
    let allTags: [String]
    var onChange: () -> Void

    @State private var newTagText = ""
    @FocusState private var isInputFocused: Bool
    @State private var highlightedIndex: Int? = nil
    @State private var textFieldHeight: CGFloat = 22
    #if os(iOS)
    @State private var isSuggestionsPopoverPresented = false
    #endif

    private var suggestions: [String] {
        let existing = Set(tags)
        let q = newTagText.lowercased()
        return allTags.filter {
            !existing.contains($0) &&
            !q.isEmpty &&
            $0.lowercased().hasPrefix(q)
        }
    }

    // Not gated on `isInputFocused`: @FocusState doesn't reliably sync here — this TextField is
    // hosted via UIHostingController inside a UITextView (the note body's own text container),
    // and that nested-first-responder setup on iOS leaves `isInputFocused` stuck at false even
    // while the field is actively receiving keystrokes. Non-empty query text is itself evidence
    // the field is in use, so it stands in as the visibility gate on both platforms.
    private var showSuggestions: Bool {
        !newTagText.isEmpty && !suggestions.isEmpty
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
                .onChange(of: newTagText) {
                    highlightedIndex = nil
                    #if os(iOS)
                    isSuggestionsPopoverPresented = showSuggestions
                    #endif
                }
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
                #if os(macOS)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    textFieldHeight = $0
                }
                // Floating overlay: NSHostingView hit-tests SwiftUI content correctly even when
                // it renders outside the view's reported frame, so this works on macOS.
                .overlay(alignment: .topLeading) {
                    if showSuggestions {
                        suggestionsDropdown
                            .offset(y: textFieldHeight + 2)
                    }
                }
                .zIndex(10)
                #else
                // A same-tree overlay (as used on macOS) is visible on iOS but untappable: this
                // TextField lives inside a UIHostingController hosted as a subview of the note's
                // UITextView, and that hosting view only hit-tests points within its
                // Auto-Layout-reported frame — content an overlay draws outside that frame falls
                // through to the UITextView underneath (placing the text cursor) instead of
                // reaching the suggestion buttons. A popover is presented by UIKit as its own
                // layer above everything, so it hit-tests correctly and — unlike laying the list
                // out inline — doesn't grow the header and push the note body down.
                .popover(isPresented: $isSuggestionsPopoverPresented, arrowEdge: .bottom) {
                    suggestionsDropdown
                        .presentationCompactAdaptation(.popover)
                }
                #endif
        }
    }

    // Sized for a 44pt-minimum touch target on iOS; macOS keeps the tighter, mouse-oriented sizing.
    #if os(iOS)
    private let rowMinHeight: CGFloat = 44
    private let rowHorizontalPadding: CGFloat = 14
    private let dropdownMinWidth: CGFloat = 220
    private let rowFont: Font = .body
    #else
    private let rowMinHeight: CGFloat = 20
    private let rowHorizontalPadding: CGFloat = 10
    private let dropdownMinWidth: CGFloat = 150
    private let rowFont: Font = .callout
    #endif

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                Button {
                    selectSuggestion(suggestion)
                } label: {
                    Text(suggestion)
                        .font(rowFont)
                        .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
                        .padding(.horizontal, rowHorizontalPadding)
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
        .frame(minWidth: dropdownMinWidth)
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
        #if os(iOS)
        isSuggestionsPopoverPresented = false
        #endif
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
