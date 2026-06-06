import Foundation
import Testing
@testable import MCPNotesCore
@testable import mcpnotes_mac

@Suite("NoteIndexer – stripMarkdown")
struct NoteIndexerStripMarkdownTests {

    @Test("plain text is unchanged")
    func plainTextUnchanged() {
        let input = "Hello world.\nThis is a plain note."
        #expect(NoteIndexer.stripMarkdown(input) == input)
    }

    @Test("ATX headings: # markers removed, text kept", arguments: [
        ("# Title", "Title"),
        ("## Section", "Section"),
        ("### Sub-section", "Sub-section"),
        ("###### H6", "H6"),
    ])
    func headingsStripped(input: String, expected: String) {
        #expect(NoteIndexer.stripMarkdown(input) == expected)
    }

    @Test("bold **text** markers removed")
    func boldAsteriskStripped() {
        #expect(NoteIndexer.stripMarkdown("This is **bold** text.") == "This is bold text.")
    }

    @Test("bold __text__ markers removed")
    func boldUnderscoreStripped() {
        #expect(NoteIndexer.stripMarkdown("This is __bold__ text.") == "This is bold text.")
    }

    @Test("italic *text* markers removed")
    func italicAsteriskStripped() {
        #expect(NoteIndexer.stripMarkdown("This is *italic* text.") == "This is italic text.")
    }

    @Test("italic _text_ markers removed")
    func italicUnderscoreStripped() {
        #expect(NoteIndexer.stripMarkdown("This is _italic_ text.") == "This is italic text.")
    }

    @Test("strikethrough ~~text~~ markers removed")
    func strikethroughStripped() {
        #expect(NoteIndexer.stripMarkdown("~~deleted text~~") == "deleted text")
    }

    @Test("inline code: backticks removed, content kept")
    func inlineCodeContentKept() {
        #expect(NoteIndexer.stripMarkdown("Use `await` here.") == "Use await here.")
    }

    @Test("fenced code block: fence markers removed, code content kept")
    func codeFenceContentKept() {
        let input = "```swift\nlet x = 42\nprint(x)\n```"
        let result = NoteIndexer.stripMarkdown(input)
        #expect(result.contains("let x = 42"))
        #expect(result.contains("print(x)"))
        #expect(result.contains("```") == false)
    }

    @Test("images removed entirely")
    func imagesRemoved() {
        let result = NoteIndexer.stripMarkdown("See ![diagram](diagram.png) for reference.")
        #expect(result.contains("![") == false)
        #expect(result.contains("diagram.png") == false)
        #expect(result.contains("See"))
        #expect(result.contains("for reference."))
    }

    @Test("markdown links: URL removed, link text kept")
    func linksTextKept() {
        #expect(NoteIndexer.stripMarkdown("Read [the docs](https://example.com).") == "Read the docs.")
    }

    @Test("wikilinks: brackets removed, target name kept")
    func wikilinksNameKept() {
        #expect(NoteIndexer.stripMarkdown("See [[Swift Concurrency]] for details.") == "See Swift Concurrency for details.")
    }

    @Test("blockquote > markers removed")
    func blockquotesStripped() {
        #expect(NoteIndexer.stripMarkdown("> A quoted line.") == "A quoted line.")
    }

    @Test("horizontal rules removed")
    func horizontalRulesRemoved() {
        let result = NoteIndexer.stripMarkdown("Before\n---\nAfter")
        #expect(result.contains("---") == false)
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
    }

    @Test("task list markers removed, item text kept", arguments: [
        ("- [ ] Buy milk", "Buy milk"),
        ("- [x] Write tests", "Write tests"),
        ("- [X] Deploy", "Deploy"),
    ])
    func taskListMarkersStripped(input: String, expected: String) {
        #expect(NoteIndexer.stripMarkdown(input) == expected)
    }

    @Test("HTML tags removed", arguments: [
        ("<em>text</em>", "text"),
        ("<br>", ""),
    ])
    func htmlTagsRemoved(input: String, expected: String) {
        #expect(NoteIndexer.stripMarkdown(input) == expected)
    }

    @Test("mixed markdown document: all markers stripped, content preserved")
    func mixedDocumentStripped() {
        let input = """
        # Meeting Notes

        **Action items** for *next sprint*:
        - Use `actor` for state isolation.

        > Remember to update [[Architecture Decisions]].

        See [WWDC talk](https://developer.apple.com) for details.
        """
        let result = NoteIndexer.stripMarkdown(input)
        #expect(result.contains("Meeting Notes"))
        #expect(result.contains("Action items"))
        #expect(result.contains("next sprint"))
        #expect(result.contains("actor"))
        #expect(result.contains("Remember to update"))
        #expect(result.contains("Architecture Decisions"))
        #expect(result.contains("WWDC talk"))
        #expect(result.contains("**") == false)
        #expect(result.contains("[[") == false)
        #expect(result.contains("](") == false)
    }
}
