import Foundation
import Testing
@testable import mcpnotes_mac

// MARK: - FrontmatterParser

@Suite("FrontmatterParser")
struct FrontmatterParserTests {

    let sampleUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    // MARK: parse – happy paths

    @Test func parsesUIDAndTags() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: [swift, macOS]
        ---

        Hello world
        """
        let result = FrontmatterParser.parse(content)
        #expect(result != nil)
        #expect(result?.uid == sampleUID)
        #expect(result?.tags == ["swift", "macOS"])
        #expect(result?.body == "Hello world")
    }

    @Test func parsesEmptyTagArray() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        Body text
        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.tags == [])
    }

    @Test func parsesBodyWithMultipleLines() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        Line one
        Line two
        Line three
        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.body == "Line one\nLine two\nLine three")
    }

    @Test func parsesEmptyBody() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.body == "")
    }

    @Test func trimsExtraWhitespaceInUID() {
        let content = """
        ---
        uid:   12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.uid == sampleUID)
    }

    // MARK: parse – failure paths

    @Test func returnsNilWhenNoFrontmatter() {
        let content = "Just plain markdown text"
        #expect(FrontmatterParser.parse(content) == nil)
    }

    @Test func returnsNilWhenMissingClosingDelimiter() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        """
        #expect(FrontmatterParser.parse(content) == nil)
    }

    @Test func returnsNilWhenUIDMissing() {
        let content = """
        ---
        tags: [swift]
        ---

        Body
        """
        #expect(FrontmatterParser.parse(content) == nil)
    }

    @Test func returnsNilWhenUIDMalformed() {
        let content = """
        ---
        uid: not-a-valid-uuid
        tags: []
        ---

        Body
        """
        #expect(FrontmatterParser.parse(content) == nil)
    }

    // MARK: serialize

    @Test func serializeProducesCorrectFormat() {
        let uid = sampleUID
        let output = FrontmatterParser.serialize(uid: uid, tags: ["a", "b"], body: "Test body")
        #expect(output.hasPrefix("---\n"))
        #expect(output.contains("uid: 12345678-1234-1234-1234-123456789ABC"))
        #expect(output.contains("tags: [a, b]"))
        #expect(output.contains("Test body"))
    }

    @Test func serializeEmptyTagsProducesBrackets() {
        let output = FrontmatterParser.serialize(uid: sampleUID, tags: [], body: "")
        #expect(output.contains("tags: []"))
    }

    // MARK: round-trip

    @Test func roundTripPreservesData() {
        let tags = ["swift", "macOS", "mcp"]
        let body = "# Title\n\nSome markdown **content**."
        let serialized = FrontmatterParser.serialize(uid: sampleUID, tags: tags, body: body)
        let parsed = FrontmatterParser.parse(serialized)
        #expect(parsed?.uid == sampleUID)
        #expect(parsed?.tags == tags)
        #expect(parsed?.body == body)
    }

    @Test func roundTripWithEmptyTags() {
        let serialized = FrontmatterParser.serialize(uid: sampleUID, tags: [], body: "")
        let parsed = FrontmatterParser.parse(serialized)
        #expect(parsed?.tags == [])
        #expect(parsed?.body == "")
    }
}
