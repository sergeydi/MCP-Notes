import Foundation

/// Compiled NSRegularExpression patterns for CommonMark + GFM syntax.
///
/// Patterns are compiled once as `static let` and shared across the framework.
/// Platform-specific rendering (AppKit/UIKit) lives in the app target.
public struct MarkdownPatterns {
    public static let headingRx = try! NSRegularExpression(
        pattern: #"^(#{1,6}) .*$"#, options: .anchorsMatchLines)
    public static let blockquoteRx = try! NSRegularExpression(
        pattern: #"^> .*$"#, options: .anchorsMatchLines)
    public static let hrRx = try! NSRegularExpression(
        pattern: #"^[-*_]{3,}\s*$"#, options: .anchorsMatchLines)
    public static let codeFenceRx = try! NSRegularExpression(
        pattern: #"^```[^\n]*$"#, options: .anchorsMatchLines)
    public static let bulletRx = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+]) "#, options: .anchorsMatchLines)
    public static let numberedRx = try! NSRegularExpression(
        pattern: #"^(\s*)(\d+\.) "#, options: .anchorsMatchLines)
    public static let taskUncheckedRx = try! NSRegularExpression(
        pattern: #"^(\s*- )(\[ \]) "#, options: .anchorsMatchLines)
    public static let taskCheckedRx = try! NSRegularExpression(
        pattern: #"^(\s*- )(\[x\]) "#, options: [.anchorsMatchLines, .caseInsensitive])
    public static let boldRx = try! NSRegularExpression(
        pattern: #"\*\*([^*\n]+)\*\*"#)
    public static let boldUnderscoreRx = try! NSRegularExpression(
        pattern: #"__([^_\n]+)__"#)
    public static let italicRx = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?!\*)([^*\n]+)(?<!\*)\*(?!\*)"#)
    public static let italicUnderscoreRx = try! NSRegularExpression(
        pattern: #"(?<!_)_(?!_)([^_\n]+)(?<!_)_(?!_)"#)
    public static let strikeRx = try! NSRegularExpression(
        pattern: #"~~([^~\n]+)~~"#)
    public static let inlineCodeRx = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`"#)
    public static let linkRx = try! NSRegularExpression(
        pattern: #"\[[^\]\n]+\]\(([^)\n]+)\)"#)
    public static let wikilinkRx = try! NSRegularExpression(
        pattern: #"(?<!!)\[\[[^\]\n]+\]\]"#)
    /// Matches bare https?:// URLs not already inside a markdown link (...)
    public static let plainUrlRx = try! NSRegularExpression(
        pattern: #"(?<!\()https?://[^\s\])\n'"<>]+"#)
    public static let imageWikilinkRx = try! NSRegularExpression(
        pattern: #"!\[\[[^\]\n]+\.(png|jpg|jpeg|gif|webp|tiff|bmp)\]\]"#,
        options: .caseInsensitive)

    /// Strips Markdown syntax down to plain text (headings, emphasis, links, code fences, etc.).
    /// Used both for RAG chunking (macOS) and for search-result snippet previews (shared UI).
    public static func stripMarkdown(_ text: String) -> String {
        var s = text
        // Code fence markers — keep code content, remove ``` lines
        s = s.replacing(/(?m)^```[^\n]*$/, with: "")
        // Inline code — keep content, remove backticks
        s = s.replacing(/`([^`\n]+)`/) { $0.output.1 }
        s = s.replacing(/`/, with: "")
        // ATX headings
        s = s.replacing(#/(?m)^#{1,6} /#, with: "")
        // Task list markers - [ ] / - [x]
        s = s.replacing(#/(?m)^- \[[ xX]\] /#, with: "")
        // Bold **text** / __text__
        s = s.replacing(/\*\*([^*\n]+)\*\*/) { $0.output.1 }
        s = s.replacing(/__([^_\n]+)__/) { $0.output.1 }
        // Italic *text* / _text_
        s = s.replacing(/\*([^*\n]+)\*/) { $0.output.1 }
        s = s.replacing(/_([^_\n]+)_/) { $0.output.1 }
        // Strikethrough ~~text~~
        s = s.replacing(/~~([^~\n]+)~~/) { $0.output.1 }
        // Images — remove entirely
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        // Markdown links [text](url) → text
        s = s.replacing(/\[([^\]]+)\]\([^)]*\)/) { $0.output.1 }
        // Wikilinks [[Name]] → Name
        s = s.replacing(/\[\[([^\]]+)\]\]/) { $0.output.1 }
        // Blockquotes
        s = s.replacing(/(?m)^> ?/, with: "")
        // Horizontal rules
        s = s.replacing(/(?m)^[-*_]{3,}\s*$/, with: "")
        // HTML tags
        s = s.replacing(/<[^>]+>/, with: "")
        return s
    }

    /// Returns code fence content ranges and full (including ``` lines) ranges for a string.
    public static func codeFenceRanges(in string: String) -> (content: [NSRange], full: [NSRange]) {
        var contentRanges: [NSRange] = []
        var fullRanges: [NSRange] = []
        var fenceOpen: (start: Int, contentStart: Int)? = nil
        let nsStr = string as NSString
        nsStr.enumerateSubstrings(
            in: NSRange(location: 0, length: nsStr.length),
            options: .byLines
        ) { sub, _, enclosing, _ in
            guard let sub else { return }
            if sub.hasPrefix("```") {
                if let open = fenceOpen {
                    contentRanges.append(NSRange(location: open.contentStart, length: enclosing.location - open.contentStart))
                    fullRanges.append(NSRange(location: open.start, length: NSMaxRange(enclosing) - open.start))
                    fenceOpen = nil
                } else {
                    fenceOpen = (start: enclosing.location, contentStart: NSMaxRange(enclosing))
                }
            }
        }
        if let open = fenceOpen {
            let len = nsStr.length
            contentRanges.append(NSRange(location: open.contentStart, length: len - open.contentStart))
            fullRanges.append(NSRange(location: open.start, length: len - open.start))
        }
        return (contentRanges, fullRanges)
    }
}
