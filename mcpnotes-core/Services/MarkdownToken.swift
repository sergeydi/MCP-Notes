import Foundation

/// A parsed syntax token: a range in the source string and its highlight style.
public struct MarkdownToken: Sendable {
    public enum Style: Sendable {
        case headingText
        case headingMarker
        case blockquoteText
        case blockquoteMarker
        case hr
        case codeFenceMarker
        case codeContent
        case listMarker
        case taskUnchecked
        case taskChecked
        case boldMarker
        case boldContent
        case italicMarker
        case italicContent
        case strikethrough
        case inlineCodeBg
        case inlineCodeContent
        case inlineCodeMarker
        case link
        case wikilink
    }

    public var range: NSRange
    public var style: Style

    public init(range: NSRange, style: Style) {
        self.range = range
        self.style = style
    }

    /// Tokenizes a Markdown string into styled ranges.
    public static func tokenize(_ string: String, codeFenceRanges: [NSRange]) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        let nsStr = string as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        func add(_ range: NSRange, _ style: Style) {
            tokens.append(MarkdownToken(range: range, style: style))
        }

        // MARK: Line-level

        MarkdownPatterns.headingRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .headingText)
            let hashRange = m.range(at: 1)
            if hashRange.location != NSNotFound {
                add(NSRange(location: hashRange.location, length: hashRange.length + 1), .headingMarker)
            }
        }

        MarkdownPatterns.blockquoteRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .blockquoteText)
            add(NSRange(location: m.range.location, length: min(2, m.range.length)), .blockquoteMarker)
        }

        MarkdownPatterns.hrRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .hr)
        }

        MarkdownPatterns.codeFenceRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .codeFenceMarker)
        }

        for fenceRange in codeFenceRanges {
            add(fenceRange, .codeContent)
        }

        MarkdownPatterns.bulletRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(sub, .listMarker)
        }

        MarkdownPatterns.numberedRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(sub, .listMarker)
        }

        MarkdownPatterns.taskUncheckedRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(sub, .taskUnchecked)
        }

        MarkdownPatterns.taskCheckedRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let sub = m.range(at: 2)
            guard sub.location != NSNotFound else { return }
            add(sub, .taskChecked)
        }

        // MARK: Inline

        MarkdownPatterns.boldRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 4 else { return }
            add(NSRange(location: m.range.location, length: 2), .boldMarker)
            add(NSRange(location: NSMaxRange(m.range) - 2, length: 2), .boldMarker)
            let content = m.range(at: 1)
            if content.location != NSNotFound { add(content, .boldContent) }
        }

        MarkdownPatterns.boldUnderscoreRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 4 else { return }
            add(NSRange(location: m.range.location, length: 2), .boldMarker)
            add(NSRange(location: NSMaxRange(m.range) - 2, length: 2), .boldMarker)
            let content = m.range(at: 1)
            if content.location != NSNotFound { add(content, .boldContent) }
        }

        MarkdownPatterns.italicRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 2 else { return }
            add(NSRange(location: m.range.location, length: 1), .italicMarker)
            add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .italicMarker)
            let content = m.range(at: 1)
            if content.location != NSNotFound { add(content, .italicContent) }
        }

        MarkdownPatterns.italicUnderscoreRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1, m.range.length > 2 else { return }
            add(NSRange(location: m.range.location, length: 1), .italicMarker)
            add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .italicMarker)
            let content = m.range(at: 1)
            if content.location != NSNotFound { add(content, .italicContent) }
        }

        MarkdownPatterns.strikeRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .strikethrough)
        }

        MarkdownPatterns.inlineCodeRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            add(m.range, .inlineCodeBg)
            let content = m.range(at: 1)
            if content.location != NSNotFound { add(content, .inlineCodeContent) }
            add(NSRange(location: m.range.location, length: 1), .inlineCodeMarker)
            add(NSRange(location: NSMaxRange(m.range) - 1, length: 1), .inlineCodeMarker)
        }

        MarkdownPatterns.linkRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .link)
        }

        MarkdownPatterns.wikilinkRx.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m else { return }
            add(m.range, .wikilink)
        }

        return tokens
    }
}
