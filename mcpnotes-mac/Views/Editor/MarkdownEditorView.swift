import SwiftUI

/// Plain-text Markdown editor backed by `TextEditor`.
///
/// Syntax highlighting and Wikilink navigation are not yet implemented;
/// those require a custom `NSTextView` subclass or a third-party library.
struct MarkdownEditorView: View {
    @Binding var text: String
    var onTextChanged: () -> Void

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: text) { _, _ in
                onTextChanged()
            }
            .accessibilityLabel("Note content")
    }
}
