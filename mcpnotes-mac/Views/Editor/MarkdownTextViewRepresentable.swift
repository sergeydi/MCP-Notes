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

        let textView = WikilinkTextView(frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0))
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
        (context.coordinator.textView as? WikilinkTextView)?.onWikilinkTapped = onWikilinkTapped
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

// MARK: - WikilinkTextView

/// NSTextView subclass that navigates to wikilinked notes and opens markdown links on click,
/// and shows a pointing-hand cursor when hovering over either link type.
private final class WikilinkTextView: NSTextView {
    var onWikilinkTapped: ((String) -> Void)?
    private var linkRects: [CGRect] = []

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
        if linkRects.contains(where: { $0.contains(point) }) {
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
            text.wrappedValue = tv.string
            onTextChanged()
            refreshHighlighting()
        }

        func refreshHighlighting() {
            guard let tv = textView else { return }
            highlighter.recomputeCodeFenceRanges(in: tv.string)
            highlighter.applyHighlights(to: tv)
            (tv as? WikilinkTextView)?.recomputeLinkRects()
        }
    }
}
