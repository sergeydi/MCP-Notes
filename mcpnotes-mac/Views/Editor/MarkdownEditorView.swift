import SwiftUI

/// Markdown editor with CommonMark + GFM syntax highlighting.
///
/// Backed by `NSTextView` with TextKit 2 rendering attributes.
/// Wikilink click-navigation is not yet implemented.
struct MarkdownEditorView: View {
    @Binding var text: String
    var onTextChanged: () -> Void

    var body: some View {
        MarkdownTextViewRepresentable(text: $text, onTextChanged: onTextChanged)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Note content")
    }
}
