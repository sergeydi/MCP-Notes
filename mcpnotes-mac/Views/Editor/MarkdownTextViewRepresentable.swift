import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var onTextChanged: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextChanged: onTextChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0))
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: monoFont])
        )
        context.coordinator.refreshHighlighting()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onTextChanged = onTextChanged
        guard let textView = context.coordinator.textView,
              text != textView.string else { return }

        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        context.coordinator.isUpdatingFromSwiftUI = true
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: monoFont])
        )
        context.coordinator.isUpdatingFromSwiftUI = false
        context.coordinator.refreshHighlighting()
    }
}

// MARK: - Coordinator

extension MarkdownTextViewRepresentable {
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onTextChanged: () -> Void
        weak var textView: NSTextView?
        var isUpdatingFromSwiftUI = false
        private var highlighter = MarkdownHighlighter()

        init(text: Binding<String>, onTextChanged: @escaping () -> Void) {
            self.text = text
            self.onTextChanged = onTextChanged
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let tv = textView else { return }
            text.wrappedValue = tv.string
            onTextChanged()
            refreshHighlighting()
        }

        func refreshHighlighting() {
            guard let tv = textView else { return }
            highlighter.recomputeCodeFenceRanges(in: tv.string)
            highlighter.applyHighlights(to: tv)
        }
    }
}
