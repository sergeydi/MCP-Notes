import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var onTextChanged: () -> Void
    var onWikilinkTapped: ((String) -> Void)?
    var notesDirectoryURL: URL?
    var formatProxy: TextFormatProxy?

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
        textView.textColor = .labelColor
        textView.onWikilinkTapped = onWikilinkTapped
        textView.notesDirectoryURL = notesDirectoryURL
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        formatProxy?.register(
            wrap: { [weak textView] open, close in
                guard let tv = textView else { return }
                let sel = tv.selectedRange()
                let nsStr = tv.string as NSString
                let targetRange: NSRange
                let replacement: String
                if sel.length > 0 {
                    let selected = nsStr.substring(with: sel)
                    if selected.contains("\n") {
                        // Multi-line selection: wrap each non-empty line individually
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
                tv.insertText(replacement, replacementRange: targetRange)
                let cursor = targetRange.location + (replacement as NSString).length
                tv.setSelectedRange(NSRange(location: cursor, length: 0))
            },
            prefix: { [weak textView] prefix in
                guard let tv = textView else { return }
                let sel = tv.selectedRange()
                let nsStr = tv.string as NSString
                let lineRange = nsStr.lineRange(for: sel)
                let parts = nsStr.substring(with: lineRange).components(separatedBy: "\n")
                let prefixed = parts.map { $0.isEmpty ? $0 : prefix + $0 }.joined(separator: "\n")
                tv.insertText(prefixed, replacementRange: lineRange)
            },
            code: { [weak textView] in
                guard let tv = textView else { return }
                let sel = tv.selectedRange()
                let nsStr = tv.string as NSString
                if sel.length > 0 {
                    let selected = nsStr.substring(with: sel)
                    if selected.contains("\n") {
                        // Multi-line selection → code block
                        tv.insertText("```\n" + selected + "\n```", replacementRange: sel)
                    } else {
                        // Single-line selection → inline code
                        tv.insertText("`" + selected + "`", replacementRange: sel)
                    }
                } else {
                    // No selection → code block around current line
                    var lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
                    if lineRange.length > 0 && nsStr.character(at: lineRange.upperBound - 1) == 10 {
                        lineRange.length -= 1
                    }
                    let lineContent = nsStr.substring(with: lineRange)
                    let replacement = "```\n" + lineContent + "\n```"
                    tv.insertText(replacement, replacementRange: lineRange)
                    let cursor = lineRange.location + (replacement as NSString).length
                    tv.setSelectedRange(NSRange(location: cursor, length: 0))
                }
            },
            insert: { [weak textView] text in
                guard let tv = textView else { return }
                let sel = tv.selectedRange()
                tv.insertText(text, replacementRange: sel)
                let cursor = sel.location + (text as NSString).length
                tv.setSelectedRange(NSRange(location: cursor, length: 0))
            }
        )

        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor])
        )
        context.coordinator.refreshHighlighting()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onTextChanged = onTextChanged
        if let mtv = context.coordinator.textView as? MarkdownTextView {
            mtv.onWikilinkTapped = onWikilinkTapped
            mtv.notesDirectoryURL = notesDirectoryURL
        }
        guard let textView = context.coordinator.textView,
              text != textView.string else { return }

        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        context.coordinator.isUpdatingFromSwiftUI = true
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor])
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
    var notesDirectoryURL: URL?
    private var linkRects: [CGRect] = []
    var codeBlockRanges: [NSRange] = []
    var codeContentRanges: [NSRange] = []
    private var copyButtons: [NSButton] = []
    private var imageViews: [NSImageView] = []
    private var lastLayoutWidth: CGFloat = 0
    private var minFrameHeight: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        var s = newSize
        if minFrameHeight > 0 { s.height = max(s.height, minFrameHeight) }
        super.setFrameSize(s)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard abs(w - lastLayoutWidth) > 1 else { return }
        lastLayoutWidth = w
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateImagePreviews()
            self.setNeedsDisplay(self.bounds)
        }
    }

    // MARK: Code block background

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeBlockRanges.isEmpty,
              let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return }

        let bg = NSColor.systemGray.withAlphaComponent(0.10)
        let origin = textContainerOrigin
        let topPad: CGFloat = 2
        let bottomPad: CGFloat = -6
        let leftMargin: CGFloat = 2
        let rightMargin: CGFloat = 10
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
                x: bounds.minX + leftMargin,
                y: minY - topPad,
                width: bounds.width - leftMargin - rightMargin,
                height: (maxY - minY) + topPad + bottomPad
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
        let topPad: CGFloat = 2
        let rightMargin: CGFloat = 10
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
                x: bounds.width - rightMargin - buttonSize - buttonPad,
                y: minY - topPad + buttonPad,
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

    // MARK: Image previews

    func updateImagePreviews() {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []
        minFrameHeight = 0

        guard let textStorage = textContentStorage?.textStorage else { return }
        let fullRange = NSRange(location: 0, length: (textStorage.string as NSString).length)
        if fullRange.length > 0 {
            textStorage.removeAttribute(.paragraphStyle, range: fullRange)
        }

        guard let notesDir = notesDirectoryURL,
              let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return }

        let str = textStorage.string
        let nsStr = str as NSString
        let matchRange = NSRange(location: 0, length: nsStr.length)
        guard matchRange.length > 0 else { return }

        struct ImageEntry {
            let lineRange: NSRange
            let image: NSImage
            let displaySize: CGSize
            let spacing: CGFloat
        }

        let maxW = max(bounds.width - 20, 100)
        let maxH = max((enclosingScrollView?.frame.height ?? bounds.height) - 40, 100)
        let topGap: CGFloat = 6
        let bottomGap: CGFloat = 6
        var entries: [ImageEntry] = []

        MarkdownPatterns.imageWikilinkRx.enumerateMatches(in: str, range: matchRange) { m, _, _ in
            guard let m else { return }
            let raw = nsStr.substring(with: m.range)
            let filename = String(raw.dropFirst(3).dropLast(2))
            let imageURL = notesDir.appendingPathComponent(filename)
            guard let image = NSImage(contentsOf: imageURL),
                  image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(min(maxW / image.size.width, maxH / image.size.height), 1.0)
            let displaySize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            entries.append(ImageEntry(
                lineRange: nsStr.lineRange(for: m.range),
                image: image,
                displaySize: displaySize,
                spacing: topGap + displaySize.height + bottomGap
            ))
        }

        guard !entries.isEmpty else { return }

        let origin = textContainerOrigin
        let base = contentStorage.documentRange.location

        // Compute line bottom Y values before adding paragraph spacing.
        // Each image's spacing shifts all subsequent lines; cumulativeShift corrects for this.
        var lineBottoms: [CGFloat] = []
        var cumulativeShift: CGFloat = 0

        for entry in entries {
            guard entry.lineRange.length > 0,
                  let startLoc = contentStorage.location(base, offsetBy: entry.lineRange.location),
                  let endLoc = contentStorage.location(startLoc, offsetBy: entry.lineRange.length) else {
                lineBottoms.append(0)
                cumulativeShift += entry.spacing
                continue
            }

            var rawMaxY: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(from: startLoc, options: [.ensuresLayout]) { frag in
                guard let er = frag.textElement?.elementRange else { return true }
                if er.location.compare(endLoc) != .orderedAscending { return false }
                let frame = frag.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
                rawMaxY = max(rawMaxY, frame.maxY)
                return true
            }

            lineBottoms.append(rawMaxY + cumulativeShift)
            cumulativeShift += entry.spacing
        }

        // Reserve vertical space for each image via paragraph spacing
        for entry in entries {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = entry.spacing
            textStorage.addAttribute(.paragraphStyle, value: style, range: entry.lineRange)
        }

        // Position image views after layout updates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (entry, lineBottom) in zip(entries, lineBottoms) {
                guard lineBottom > 0 else { continue }
                let iv = NSImageView()
                iv.image = entry.image
                iv.imageScaling = .scaleAxesIndependently
                iv.imageAlignment = .alignLeft
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 4
                iv.layer?.masksToBounds = true
                iv.frame = CGRect(
                    x: self.textContainerOrigin.x + 2,
                    y: lineBottom + topGap,
                    width: entry.displaySize.width,
                    height: entry.displaySize.height
                )
                self.addSubview(iv)
                self.imageViews.append(iv)
            }
            if let lastIV = self.imageViews.last {
                self.minFrameHeight = lastIV.frame.maxY + bottomGap
            } else {
                self.minFrameHeight = 0
            }
            self.sizeToFit()
        }
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

        MarkdownPatterns.wikilinkRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            addRects(for: m.range)
        }
        MarkdownPatterns.linkRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            addRects(for: m.range)
        }
        MarkdownPatterns.plainUrlRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            addRects(for: m.range)
        }
        linkRects = rects
    }

    // MARK: Paste image

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), notesDirectoryURL != nil {
            let types = NSPasteboard.general.types ?? []
            if types.contains(.tiff) || types.contains(.png) ||
               NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
                return true
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        guard let notesDir = notesDirectoryURL,
              let pngData = Self.imagePNGData(from: .general) else {
            super.paste(sender)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: Date())
        var filename = "Pasted image \(timestamp).png"
        var fileURL = notesDir.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            filename = "Pasted image \(timestamp)-\(counter).png"
            fileURL = notesDir.appendingPathComponent(filename)
            counter += 1
        }

        guard (try? pngData.write(to: fileURL)) != nil else {
            super.paste(sender)
            return
        }

        let wikilink = "![[\(filename)]]"
        if shouldChangeText(in: selectedRange(), replacementString: wikilink) {
            replaceCharacters(in: selectedRange(), with: wikilink)
            didChangeText()
        }
    }

    private static func imagePNGData(from pb: NSPasteboard) -> Data? {
        // PNG direct
        if let data = pb.data(forType: .png) { return data }
        // TIFF (screenshots, most apps)
        if let data = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data) {
            return rep.representation(using: .png, properties: [:])
        }
        // File URL pointing to an image
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        // Generic NSImage fallback
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    // MARK: List continuation

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let nsStr = string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = nsStr.substring(with: lineRange)

        guard let (prefixLen, continuation) = MarkdownListContinuation.info(for: line) else {
            super.insertNewline(sender)
            return
        }

        let body = String(line.dropFirst(prefixLen)).trimmingCharacters(in: .newlines)
        if body.isEmpty {
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
        let replacements = MarkdownListContinuation.renumberingReplacements(in: string)
        guard !replacements.isEmpty else { return }
        for (range, replacement) in replacements.reversed() {
            textStorage?.replaceCharacters(in: range, with: replacement)
        }
    }

    // MARK: Click navigation

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // super runs a tracking loop, so by here the full click/drag is done.
        // Only navigate when no text was selected (pure click, not a drag-select).
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let charIdx = selectedRange().location
        guard charIdx != NSNotFound else { return }
        let nsStr = string as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        // Wikilinks: [[Note Name]]
        MarkdownPatterns.wikilinkRx.enumerateMatches(in: string, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range) else { return }
            let nameRange = NSRange(location: m.range.location + 2, length: m.range.length - 4)
            guard nameRange.length > 0 else { return }
            self.onWikilinkTapped?(nsStr.substring(with: nameRange))
            stop.pointee = true
        }

        // Markdown links: [text](url)
        MarkdownPatterns.linkRx.enumerateMatches(in: string, range: fullRange) { m, _, stop in
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

        // Plain URLs: https://...
        MarkdownPatterns.plainUrlRx.enumerateMatches(in: string, range: fullRange) { m, _, stop in
            guard let m, NSLocationInRange(charIdx, m.range) else { return }
            let urlString = nsStr.substring(with: m.range)
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
                wv.updateImagePreviews()
                wv.setNeedsDisplay(wv.bounds)
                DispatchQueue.main.async { wv.updateCopyButtons() }
            }
        }
    }
}
