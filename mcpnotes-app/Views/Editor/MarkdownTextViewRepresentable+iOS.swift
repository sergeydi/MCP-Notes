import SwiftUI
import UIKit

// MARK: - iOS (UITextView-based MVP)
//
// Feature parity with macOS: syntax highlighting, wikilink/link tap navigation,
// list auto-continuation + renumbering, toolbar formatting via TextFormatProxy.
// Deferred to a later pass: pasted-image insertion/inline preview, code-block copy button.

struct MarkdownTextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    var onTextChanged: () -> Void
    var onWikilinkTapped: ((String) -> Void)?
    var notesDirectoryURL: URL?
    var formatProxy: TextFormatProxy?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextChanged: onTextChanged)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownTextView()
        textView.isEditable = true
        textView.isScrollEnabled = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.onWikilinkTapped = onWikilinkTapped
        textView.notesDirectoryURL = notesDirectoryURL
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let tap = UITapGestureRecognizer(target: textView, action: #selector(MarkdownTextView.handleTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)

        formatProxy?.register(
            wrap: { [weak textView] open, close in
                guard let tv = textView else { return }
                let sel = tv.selectedRange
                let nsStr = (tv.text ?? "") as NSString
                let targetRange: NSRange
                let replacement: String
                if sel.length > 0 {
                    let selected = nsStr.substring(with: sel)
                    if selected.contains("\n") {
                        let parts = selected.components(separatedBy: "\n")
                        replacement = parts.map { $0.isEmpty ? $0 : open + $0 + close }.joined(separator: "\n")
                    } else {
                        replacement = open + selected + close
                    }
                    targetRange = sel
                } else {
                    var lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
                    if lineRange.length > 0 && nsStr.character(at: lineRange.upperBound - 1) == 10 {
                        lineRange.length -= 1
                    }
                    targetRange = lineRange
                    replacement = open + nsStr.substring(with: lineRange) + close
                }
                tv.replaceText(in: targetRange, with: replacement)
                let cursor = targetRange.location + (replacement as NSString).length
                tv.selectedRange = NSRange(location: cursor, length: 0)
            },
            prefix: { [weak textView] prefix in
                guard let tv = textView else { return }
                let sel = tv.selectedRange
                let nsStr = (tv.text ?? "") as NSString
                let lineRange = nsStr.lineRange(for: sel)
                let parts = nsStr.substring(with: lineRange).components(separatedBy: "\n")
                let prefixed = parts.map { $0.isEmpty ? $0 : prefix + $0 }.joined(separator: "\n")
                tv.replaceText(in: lineRange, with: prefixed)
            },
            code: { [weak textView] in
                guard let tv = textView else { return }
                let sel = tv.selectedRange
                let nsStr = (tv.text ?? "") as NSString
                if sel.length > 0 {
                    let selected = nsStr.substring(with: sel)
                    if selected.contains("\n") {
                        tv.replaceText(in: sel, with: "```\n" + selected + "\n```")
                    } else {
                        tv.replaceText(in: sel, with: "`" + selected + "`")
                    }
                } else {
                    var lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
                    if lineRange.length > 0 && nsStr.character(at: lineRange.upperBound - 1) == 10 {
                        lineRange.length -= 1
                    }
                    let lineContent = nsStr.substring(with: lineRange)
                    let replacement = "```\n" + lineContent + "\n```"
                    tv.replaceText(in: lineRange, with: replacement)
                    let cursor = lineRange.location + (replacement as NSString).length
                    tv.selectedRange = NSRange(location: cursor, length: 0)
                }
            },
            insert: { [weak textView] text in
                guard let tv = textView else { return }
                let sel = tv.selectedRange
                tv.replaceText(in: sel, with: text)
                let cursor = sel.location + (text as NSString).length
                tv.selectedRange = NSRange(location: cursor, length: 0)
            }
        )

        let monoFont = UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        textView.markdownContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: monoFont, .foregroundColor: UIColor.label])
        )
        context.coordinator.refreshHighlighting()

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onTextChanged = onTextChanged
        if let mtv = context.coordinator.textView as? MarkdownTextView {
            mtv.onWikilinkTapped = onWikilinkTapped
            mtv.notesDirectoryURL = notesDirectoryURL
        }
        guard let textView = context.coordinator.textView,
              text != textView.text else { return }

        let monoFont = UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        context.coordinator.isUpdatingFromSwiftUI = true
        textView.markdownContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: monoFont, .foregroundColor: UIColor.label])
        )
        context.coordinator.isUpdatingFromSwiftUI = false
        context.coordinator.refreshHighlighting()
    }
}

private extension UITextView {
    /// Converts an `NSRange` to `UITextRange` and replaces its contents.
    func replaceText(in range: NSRange, with replacement: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = self.textRange(from: start, to: end) else { return }
        replace(textRange, withText: replacement)
    }

    /// UITextView (unlike NSTextView) exposes `.textLayoutManager` but not `.textContentStorage`
    /// directly — it's reached via the layout manager's generic `textContentManager`.
    var markdownContentStorage: NSTextContentStorage? {
        textLayoutManager?.textContentManager as? NSTextContentStorage
    }
}

// MARK: - MarkdownTextView (iOS)

/// UITextView subclass with markdown-aware behaviour: click navigation for wikilinks/URLs
/// and list auto-continuation. Mirrors the macOS `MarkdownTextView` (NSTextView) feature set,
/// minus pasted-image preview and the code-block copy button (deferred).
private final class MarkdownTextView: UITextView {
    var onWikilinkTapped: ((String) -> Void)?
    var notesDirectoryURL: URL?

    // MARK: List continuation

    override func insertText(_ text: String) {
        guard text == "\n" else {
            super.insertText(text)
            return
        }
        let sel = selectedRange
        let nsStr = (self.text ?? "") as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = nsStr.substring(with: lineRange)

        guard let (prefixLen, continuation) = MarkdownListContinuation.info(for: line) else {
            super.insertText(text)
            return
        }

        let body = String(line.dropFirst(prefixLen)).trimmingCharacters(in: .newlines)
        if body.isEmpty {
            replaceText(in: NSRange(location: lineRange.location, length: prefixLen), with: "")
        } else {
            super.insertText(text)
            replaceText(in: selectedRange, with: continuation)
        }
    }

    /// Scans all lines and renumbers any numbered list sections where items are out of sequence.
    /// Applied directly to textStorage to avoid re-entering the UITextViewDelegate change pipeline.
    fileprivate func renumberAllLists() {
        let replacements = MarkdownListContinuation.renumberingReplacements(in: text ?? "")
        guard !replacements.isEmpty else { return }
        for (range, replacement) in replacements.reversed() {
            markdownContentStorage?.textStorage?.replaceCharacters(in: range, with: replacement)
        }
    }

    // MARK: Click navigation

    @objc fileprivate func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let position = closestPosition(to: gesture.location(in: self)) else { return }
        let charIdx = offset(from: beginningOfDocument, to: position)
        let str = text ?? ""
        let nsStr = str as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)
        guard charIdx != NSNotFound, charIdx >= 0, charIdx <= nsStr.length else { return }

        var handled = false

        // Wikilinks: [[Note Name]]
        MarkdownPatterns.wikilinkRx.enumerateMatches(in: str, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range) else { return }
            let nameRange = NSRange(location: m.range.location + 2, length: m.range.length - 4)
            guard nameRange.length > 0 else { return }
            self.onWikilinkTapped?(nsStr.substring(with: nameRange))
            handled = true
            stop.pointee = true
        }
        guard !handled else { return }

        // Markdown links: [text](url)
        MarkdownPatterns.linkRx.enumerateMatches(in: str, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range), m.numberOfRanges > 1 else { return }
            let urlRange = m.range(at: 1)
            guard urlRange.location != NSNotFound, urlRange.length > 0 else { return }
            if let url = URL(string: nsStr.substring(with: urlRange)) {
                UIApplication.shared.open(url)
            }
            handled = true
            stop.pointee = true
        }
        guard !handled else { return }

        // Plain URLs: https://...
        MarkdownPatterns.plainUrlRx.enumerateMatches(in: str, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range) else { return }
            if let url = URL(string: nsStr.substring(with: m.range)) {
                UIApplication.shared.open(url)
            }
            stop.pointee = true
        }
    }
}

// MARK: - Coordinator (iOS)

extension MarkdownTextViewRepresentable {
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onTextChanged: () -> Void
        weak var textView: UITextView?
        var isUpdatingFromSwiftUI = false
        private var isRenumbering = false
        private var highlighter = MarkdownHighlighter()

        init(text: Binding<String>, onTextChanged: @escaping () -> Void) {
            self.text = text
            self.onTextChanged = onTextChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingFromSwiftUI, !isRenumbering else { return }
            isRenumbering = true
            (textView as? MarkdownTextView)?.renumberAllLists()
            isRenumbering = false
            text.wrappedValue = textView.text
            onTextChanged()
            refreshHighlighting()
        }

        func refreshHighlighting() {
            guard let tv = textView else { return }
            highlighter.recomputeCodeFenceRanges(in: tv.text ?? "")
            highlighter.applyHighlights(to: tv)
        }
    }
}
