import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var onTextChanged: () -> Void
    var onWikilinkTapped: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextChanged: onTextChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0))
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
        textView.onWikilinkTapped = onWikilinkTapped
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
        (context.coordinator.textView as? MarkdownTextView)?.onWikilinkTapped = onWikilinkTapped
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

// MARK: - MarkdownTextView

/// NSTextView subclass with markdown-aware behaviour: code block background drawing,
/// pointing-hand cursor and click navigation for wikilinks and URLs, and list auto-continuation.
private final class MarkdownTextView: NSTextView {
    var onWikilinkTapped: ((String) -> Void)?
    private var linkRects: [CGRect] = []
    var codeBlockRanges: [NSRange] = []
    var codeContentRanges: [NSRange] = []
    private var copyButtons: [NSButton] = []

    // MARK: Code block background

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeBlockRanges.isEmpty,
              let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return }

        let bg = NSColor.systemGray.withAlphaComponent(0.10)
        let origin = textContainerOrigin
        let vertPad: CGFloat = 4
        let horzMargin: CGFloat = 2
        let cornerRadius: CGFloat = 6

        for nsRange in codeBlockRanges {
            let base = contentStorage.documentRange.location
            guard let startLoc = contentStorage.location(base, offsetBy: nsRange.location),
                  let endLoc = contentStorage.location(startLoc, offsetBy: nsRange.length) else { continue }

            var minY: CGFloat = .greatestFiniteMagnitude
            var maxY: CGFloat = -.greatestFiniteMagnitude

            layoutManager.enumerateTextLayoutFragments(from: startLoc, options: [.ensuresLayout]) { fragment in
                if let elemRange = fragment.textElement?.elementRange,
                   elemRange.location.compare(endLoc) != .orderedAscending { return false }
                let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
                return true
            }

            guard minY < maxY else { continue }

            let blockRect = CGRect(
                x: bounds.minX + horzMargin,
                y: minY - vertPad,
                width: bounds.width - 2 * horzMargin,
                height: (maxY - minY) + 2 * vertPad
            )
            bg.setFill()
            NSBezierPath(roundedRect: blockRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
    }

    // MARK: Copy buttons

    func updateCopyButtons() {
        copyButtons.forEach { $0.removeFromSuperview() }
        copyButtons = []

        guard !codeBlockRanges.isEmpty,
              let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return }

        let origin = textContainerOrigin
        let vertPad: CGFloat = 4
        let horzMargin: CGFloat = 2
        let buttonSize: CGFloat = 22
        let buttonPad: CGFloat = 5

        for (index, nsRange) in codeBlockRanges.enumerated() {
            let base = contentStorage.documentRange.location
            guard let startLoc = contentStorage.location(base, offsetBy: nsRange.location),
                  let endLoc = contentStorage.location(startLoc, offsetBy: nsRange.length) else { continue }

            var minY: CGFloat = .greatestFiniteMagnitude
            layoutManager.enumerateTextLayoutFragments(from: startLoc, options: [.ensuresLayout]) { fragment in
                if let elemRange = fragment.textElement?.elementRange,
                   elemRange.location.compare(endLoc) != .orderedAscending { return false }
                minY = min(minY, fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y).minY)
                return true
            }
            guard minY < .greatestFiniteMagnitude else { continue }

            let button = NSButton()
            let symConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")?
                .withSymbolConfiguration(symConfig)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Copy"
            button.tag = index
            button.target = self
            button.action = #selector(copyCodeBlock(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            button.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
            button.frame = CGRect(
                x: bounds.width - horzMargin - buttonSize - buttonPad,
                y: minY - vertPad + buttonPad,
                width: buttonSize,
                height: buttonSize
            )
            addSubview(button)
            copyButtons.append(button)
        }
    }

    @objc private func copyCodeBlock(_ sender: NSButton) {
        let index = sender.tag
        guard index < codeContentRanges.count else { return }
        let nsRange = codeContentRanges[index]
        let nsStr = string as NSString
        guard nsRange.location + nsRange.length <= nsStr.length else { return }
        let content = nsStr.substring(with: nsRange)
            .trimmingCharacters(in: .newlines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    // MARK: Cursor appearance

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if copyButtons.contains(where: { $0.frame.contains(point) }) {
            NSCursor.arrow.set()
        } else if linkRects.contains(where: { $0.contains(point) }) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    func recomputeLinkRects() {
        guard let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage,
              let textStorage = contentStorage.textStorage else {
            linkRects = []
            return
        }
        let str = textStorage.string
        let fullRange = NSRange(location: 0, length: (str as NSString).length)
        let origin = textContainerOrigin
        var rects: [CGRect] = []

        func addRects(for nsRange: NSRange) {
            let base = contentStorage.documentRange.location
            guard let start = contentStorage.location(base, offsetBy: nsRange.location),
                  let end = contentStorage.location(start, offsetBy: nsRange.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segmentFrame, _, _ in
                rects.append(segmentFrame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
        }

        MarkdownHighlighter.wikilinkRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            addRects(for: m.range)
        }
        MarkdownHighlighter.linkRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            addRects(for: m.range)
        }
        linkRects = rects
    }

    // MARK: List continuation

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let nsStr = string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = nsStr.substring(with: lineRange)

        guard let (prefixLen, continuation) = listPrefixInfo(in: line) else {
            super.insertNewline(sender)
            return
        }

        let body = String(line.dropFirst(prefixLen)).trimmingCharacters(in: .newlines)
        if body.isEmpty {
            // Empty list item — exit the list by removing the prefix
            let deleteRange = NSRange(location: lineRange.location, length: prefixLen)
            if shouldChangeText(in: deleteRange, replacementString: "") {
                textStorage?.replaceCharacters(in: deleteRange, with: "")
                didChangeText()
            }
        } else {
            super.insertNewline(sender)
            insertText(continuation, replacementRange: selectedRange())
        }
    }

    /// Scans all lines and renumbers any numbered list sections where items are out of sequence.
    /// Applied directly to textStorage without shouldChangeText/didChangeText to avoid recursion.
    fileprivate func renumberAllLists() {
        let nsStr = string as NSString
        let length = nsStr.length
        var pos = 0
        var replacements: [(NSRange, String)] = []
        // Maps indent string → next expected number for that nesting level.
        var contexts: [String: Int] = [:]

        while pos < length {
            let lineRange = nsStr.lineRange(for: NSRange(location: pos, length: 0))
            let line = nsStr.substring(with: lineRange)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(line.prefix(line.count - trimmed.count))
            var digits = ""
            var rest = String(trimmed)
            while let ch = rest.first, ch.isNumber { digits.append(ch); rest = String(rest.dropFirst()) }

            if !digits.isEmpty, rest.hasPrefix(". "), let n = Int(digits) {
                if let expected = contexts[indent] {
                    if n != expected {
                        let oldLen = indent.count + digits.count + 2
                        replacements.append((NSRange(location: lineRange.location, length: oldLen), indent + "\(expected). "))
                    }
                    contexts[indent] = expected + 1
                } else {
                    contexts[indent] = n + 1
                }
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contexts.removeAll()
            }
            pos = NSMaxRange(lineRange)
        }

        guard !replacements.isEmpty else { return }
        for (range, replacement) in replacements.reversed() {
            textStorage?.replaceCharacters(in: range, with: replacement)
        }
    }

    /// Returns (original prefix char length, continuation prefix) for list lines.
    private func listPrefixInfo(in line: String) -> (Int, String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = String(line.prefix(line.count - trimmed.count))

        // Task list must be checked before plain "- "
        for marker in ["- [ ] ", "- [x] ", "- [X] "] {
            if trimmed.hasPrefix(marker) { return (indent.count + marker.count, indent + "- [ ] ") }
        }
        // Unordered bullets
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) { return (indent.count + marker.count, indent + marker) }
        }
        // Numbered list: \d+\.
        var digits = ""
        var rest = String(trimmed)
        while let ch = rest.first, ch.isNumber { digits.append(ch); rest = String(rest.dropFirst()) }
        if !digits.isEmpty, rest.hasPrefix(". "), let n = Int(digits) {
            return (indent.count + digits.count + 2, indent + "\(n + 1). ")
        }
        return nil
    }

    // MARK: Click navigation

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1 else { return }
        let charIdx = selectedRange().location
        guard charIdx != NSNotFound else { return }
        let nsStr = string as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        // Wikilinks: [[Note Name]]
        MarkdownHighlighter.wikilinkRx.enumerateMatches(in: string, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range) else { return }
            let nameRange = NSRange(location: m.range.location + 2, length: m.range.length - 4)
            guard nameRange.length > 0 else { return }
            self.onWikilinkTapped?(nsStr.substring(with: nameRange))
            stop.pointee = true
        }

        // Markdown links: [text](url)
        MarkdownHighlighter.linkRx.enumerateMatches(in: string, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range),
                  m.numberOfRanges > 1 else { return }
            let urlRange = m.range(at: 1)
            guard urlRange.location != NSNotFound, urlRange.length > 0 else { return }
            let urlString = nsStr.substring(with: urlRange)
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            stop.pointee = true
        }
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
            (tv as? MarkdownTextView)?.renumberAllLists()
            text.wrappedValue = tv.string
            onTextChanged()
            refreshHighlighting()
        }

        func refreshHighlighting() {
            guard let tv = textView else { return }
            highlighter.recomputeCodeFenceRanges(in: tv.string)
            highlighter.applyHighlights(to: tv)
            (tv as? MarkdownTextView)?.recomputeLinkRects()
            if let wv = tv as? MarkdownTextView {
                wv.codeBlockRanges = highlighter.codeFenceFullRanges
                wv.codeContentRanges = highlighter.codeFenceRanges
                wv.setNeedsDisplay(wv.bounds)
                DispatchQueue.main.async { wv.updateCopyButtons() }
            }
        }
    }
}
