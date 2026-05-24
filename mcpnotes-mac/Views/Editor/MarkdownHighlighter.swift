import AppKit

/// Applies TextKit 2 rendering attributes for CommonMark + GFM syntax highlighting.
///
/// Non-destructive: only touches rendering attributes on `NSTextLayoutManager`,
/// leaving `NSTextStorage` (and the on-disk Markdown) as plain text.
struct MarkdownHighlighter {
    private(set) var codeFenceRanges: [NSRange] = []

    // MARK: Regex patterns (compiled once)

    private static let headingRx = try! NSRegularExpression(
        pattern: #"^(#{1,6}) .*$"#, options: .anchorsMatchLines)
    private static let blockquoteRx = try! NSRegularExpression(
        pattern: #"^> .*$"#, options: .anchorsMatchLines)
    private static let hrRx = try! NSRegularExpression(
        pattern: #"^[-*_]{3,}\s*$"#, options: .anchorsMatchLines)
    private static let codeFenceRx = try! NSRegularExpression(
        pattern: #"^```[^\n]*$"#, options: .anchorsMatchLines)
    private static let bulletRx = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+]) "#, options: .anchorsMatchLines)
    private static let numberedRx = try! NSRegularExpression(
        pattern: #"^(\s*)(\d+\.) "#, options: .anchorsMatchLines)
    private static let taskUncheckedRx = try! NSRegularExpression(
        pattern: #"^(\s*- )(\[ \]) "#, options: .anchorsMatchLines)
    private static let taskCheckedRx = try! NSRegularExpression(
        pattern: #"^(\s*- )(\[x\]) "#, options: [.anchorsMatchLines, .caseInsensitive])
    private static let boldRx = try! NSRegularExpression(
        pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let boldUnderscoreRx = try! NSRegularExpression(
        pattern: #"__([^_\n]+)__"#)
    private static let italicRx = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?!\*)([^*\n]+)(?<!\*)\*(?!\*)"#)
    private static let italicUnderscoreRx = try! NSRegularExpression(
        pattern: #"(?<!_)_(?!_)([^_\n]+)(?<!_)_(?!_)"#)
    private static let strikeRx = try! NSRegularExpression(
        pattern: #"~~([^~\n]+)~~"#)
    private static let inlineCodeRx = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`"#)
    static let linkRx = try! NSRegularExpression(
        pattern: #"\[[^\]\n]+\]\(([^)\n]+)\)"#)
    static let wikilinkRx = try! NSRegularExpression(
        pattern: #"\[\[[^\]\n]+\]\]"#)

    // MARK: Code fence tracking

    mutating func recomputeCodeFenceRanges(in string: String) {
        var result: [NSRange] = []
        var openEnd: Int? = nil
        let nsStr = string as NSString
        nsStr.enumerateSubstrings(
            in: NSRange(location: 0, length: nsStr.length),
            options: .byLines
        ) { sub, _, enclosing, _ in
            guard let sub else { return }
            if sub.hasPrefix("```") {
                if let start = openEnd {
                    result.append(NSRange(location: start, length: enclosing.location - start))
                    openEnd = nil
                } else {
                    openEnd = NSMaxRange(enclosing)
                }
            }
        }
        if let start = openEnd {
            result.append(NSRange(location: start, length: nsStr.length - start))
        }
        codeFenceRanges = result
    }

    // MARK: Highlighting

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

        func add(_ key: NSAttributedString.Key, _ value: Any, _ r: NSRange) {
            guard let range = tr(r) else { return }
            layoutManager.addRenderingAttribute(key, value: value, for: range)
        }

        func setFont(_ font: NSFont, _ r: NSRange) {
            guard r.location != NSNotFound, r.length > 0,
                  r.location + r.length <= nsStr.length else { return }
            textStorage.addAttribute(.font, value: font, range: r)
        }

        // MARK: Line-level elements

        Self.headingRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.systemBlue, m.range)
            setFont(boldFont, m.range)
            let hashRange = m.range(at: 1)
            if hashRange.location != NSNotFound {
                let markerRange = NSRange(location: hashRange.location, length: hashRange.length + 1)
                add(.foregroundColor, NSColor.tertiaryLabelColor, markerRange)
                setFont(monoFont, markerRange)
            }
        }

        Self.blockquoteRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.secondaryLabelColor, m.range)
            let markerRange = NSRange(location: m.range.location, length: min(2, m.range.length))
            add(.foregroundColor, NSColor.systemOrange.withAlphaComponent(0.7), markerRange)
        }

        Self.hrRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.separatorColor, m.range)
        }

        Self.codeFenceRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.systemGreen, m.range)
        }

        for fenceRange in codeFenceRanges {
            add(.foregroundColor, NSColor.systemGreen, fenceRange)
            add(.backgroundColor, NSColor.systemGray.withAlphaComponent(0.08), fenceRange)
        }

        Self.bulletRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(.foregroundColor, NSColor.tertiaryLabelColor, sub)
        }

        Self.numberedRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(.foregroundColor, NSColor.tertiaryLabelColor, sub)
        }

        Self.taskUncheckedRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(.foregroundColor, NSColor.systemOrange, sub)
        }

        Self.taskCheckedRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(.foregroundColor, NSColor.systemGreen, sub)
        }

        // MARK: Inline elements

        Self.boldRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 4 else { return }
            let open = NSRange(location: m.range.location, length: 2)
            let close = NSRange(location: NSMaxRange(m.range) - 2, length: 2)
            let content = m.range(at: 1)
            add(.foregroundColor, NSColor.quaternaryLabelColor, open)
            add(.foregroundColor, NSColor.quaternaryLabelColor, close)
            if content.location != NSNotFound { setFont(boldFont, content) }
        }

        Self.boldUnderscoreRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 4 else { return }
            let open = NSRange(location: m.range.location, length: 2)
            let close = NSRange(location: NSMaxRange(m.range) - 2, length: 2)
            let content = m.range(at: 1)
            add(.foregroundColor, NSColor.quaternaryLabelColor, open)
            add(.foregroundColor, NSColor.quaternaryLabelColor, close)
            if content.location != NSNotFound { setFont(boldFont, content) }
        }

        Self.italicRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 2 else { return }
            let open = NSRange(location: m.range.location, length: 1)
            let close = NSRange(location: NSMaxRange(m.range) - 1, length: 1)
            let content = m.range(at: 1)
            add(.foregroundColor, NSColor.quaternaryLabelColor, open)
            add(.foregroundColor, NSColor.quaternaryLabelColor, close)
            if content.location != NSNotFound { setFont(italicFont, content) }
        }

        Self.italicUnderscoreRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 2 else { return }
            let open = NSRange(location: m.range.location, length: 1)
            let close = NSRange(location: NSMaxRange(m.range) - 1, length: 1)
            let content = m.range(at: 1)
            add(.foregroundColor, NSColor.quaternaryLabelColor, open)
            add(.foregroundColor, NSColor.quaternaryLabelColor, close)
            if content.location != NSNotFound { setFont(italicFont, content) }
        }

        Self.strikeRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.secondaryLabelColor, m.range)
            textStorage.addAttribute(.strikethroughStyle, value: NSNumber(value: NSUnderlineStyle.single.rawValue), range: m.range)
        }

        Self.inlineCodeRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.systemGreen, m.range)
        }

        Self.linkRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.linkColor, m.range)
        }

        Self.wikilinkRx.enumerateMatches(in: str, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(.foregroundColor, NSColor.systemPurple, m.range)
        }

        textView.needsDisplay = true
    }
}
