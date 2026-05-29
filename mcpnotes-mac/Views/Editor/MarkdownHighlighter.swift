import AppKit
import MCPNotesCore

/// Applies TextKit 2 rendering attributes for CommonMark + GFM syntax highlighting.
///
/// Non-destructive: only touches rendering attributes on `NSTextLayoutManager`,
/// leaving `NSTextStorage` (and the on-disk Markdown) as plain text.
struct MarkdownHighlighter {
    private(set) var codeFenceRanges: [NSRange] = []
    /// Full ranges including the opening and closing ``` marker lines.
    private(set) var codeFenceFullRanges: [NSRange] = []

    mutating func recomputeCodeFenceRanges(in string: String) {
        let result = MarkdownPatterns.codeFenceRanges(in: string)
        codeFenceRanges = result.content
        codeFenceFullRanges = result.full
    }

    func applyHighlights(to textView: NSTextView) {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = textView.textContentStorage,
              let textStorage = contentStorage.textStorage else { return }

        let str = textStorage.string
        let nsStr = str as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)
        let docRange = layoutManager.documentRange
        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        let italicFont = NSFont(descriptor: monoFont.fontDescriptor.withSymbolicTraits(.italic), size: monoFont.pointSize) ?? monoFont

        for key: NSAttributedString.Key in [.foregroundColor, .backgroundColor] {
            layoutManager.removeRenderingAttribute(key, for: docRange)
        }
        // Font and strikethrough must go through textStorage — addRenderingAttribute has no visual effect for these.
        textStorage.addAttribute(.font, value: monoFont, range: fullRange)
        textStorage.removeAttribute(.strikethroughStyle, range: fullRange)

        func tr(_ r: NSRange) -> NSTextRange? {
            guard r.location != NSNotFound, r.length >= 0,
                  r.location + r.length <= nsStr.length else { return nil }
            let base = contentStorage.documentRange.location
            guard let s = contentStorage.location(base, offsetBy: r.location),
                  let e = contentStorage.location(s, offsetBy: r.length) else { return nil }
            return NSTextRange(location: s, end: e)
        }

        func addFg(_ color: NSColor, _ r: NSRange) {
            guard let range = tr(r) else { return }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: range)
        }

        func addBg(_ color: NSColor, _ r: NSRange) {
            guard let range = tr(r) else { return }
            layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: range)
        }

        func setFont(_ font: NSFont, _ r: NSRange) {
            guard r.location != NSNotFound, r.length > 0,
                  r.location + r.length <= nsStr.length else { return }
            textStorage.addAttribute(.font, value: font, range: r)
        }

        for token in MarkdownToken.tokenize(str, codeFenceRanges: codeFenceRanges) {
            switch token.style {
            case .headingText:
                addFg(.systemBlue, token.range)
                setFont(boldFont, token.range)
            case .headingMarker:
                addFg(.tertiaryLabelColor, token.range)
                setFont(monoFont, token.range)
            case .blockquoteText:
                addFg(.secondaryLabelColor, token.range)
            case .blockquoteMarker:
                addFg(.systemOrange.withAlphaComponent(0.7), token.range)
            case .hr:
                addFg(.separatorColor, token.range)
            case .codeFenceMarker:
                addFg(.tertiaryLabelColor, token.range)
            case .codeContent:
                addFg(.labelColor, token.range)
            case .listMarker:
                addFg(.tertiaryLabelColor, token.range)
            case .taskUnchecked:
                addFg(.systemOrange, token.range)
            case .taskChecked:
                addFg(.labelColor, token.range)
            case .boldMarker:
                addFg(.quaternaryLabelColor, token.range)
            case .boldContent:
                setFont(boldFont, token.range)
            case .italicMarker:
                addFg(.quaternaryLabelColor, token.range)
            case .italicContent:
                setFont(italicFont, token.range)
            case .strikethrough:
                addFg(.secondaryLabelColor, token.range)
                let r = token.range
                guard r.location != NSNotFound, r.length > 0,
                      r.location + r.length <= nsStr.length else { break }
                textStorage.addAttribute(.strikethroughStyle, value: NSNumber(value: NSUnderlineStyle.single.rawValue), range: r)
            case .inlineCodeBg:
                addBg(.systemGray.withAlphaComponent(0.10), token.range)
            case .inlineCodeContent:
                addFg(.labelColor, token.range)
            case .inlineCodeMarker:
                addFg(.tertiaryLabelColor, token.range)
            case .link:
                addFg(.linkColor, token.range)
            case .wikilink:
                addFg(.systemPurple, token.range)
            }
        }

        textView.needsDisplay = true
    }
}
