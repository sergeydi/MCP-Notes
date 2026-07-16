import Foundation
import Testing
@testable import mcpnotes_app

// MARK: - FrontmatterParser

@Suite("FrontmatterParser")
struct FrontmatterParserTests {

    let sampleUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    // MARK: parse – happy paths

    @Test func parsesUIDAndTags() throws {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: [swift, macOS]
        ---

        Hello world
        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.uid == sampleUID)
        #expect(result.tags == ["swift", "macOS"])
        #expect(result.body == "Hello world")
    }

    @Test func parsesEmptyTagArray() throws {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        Body text
        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.tags == [])
    }

    @Test func parsesBodyWithMultipleLines() throws {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        Line one
        Line two
        Line three
        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.body == "Line one\nLine two\nLine three")
    }

    @Test func parsesEmptyBody() throws {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.body == "")
    }

    @Test func trimsExtraWhitespaceInUID() throws {
        let content = """
        ---
        uid:   12345678-1234-1234-1234-123456789ABC
        tags: []
        ---

        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.uid == sampleUID)
    }

    // MARK: parse – failure paths

    @Test func returnsNilWhenNoFrontmatter() {
        let content = "Just plain markdown text"
        #expect(FrontmatterParser.parse(content) == nil)
    }

    @Test func parsesLegacyFormatWithoutClosingDelimiter() throws {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.uid == sampleUID)
        #expect(result.tags == [])
        #expect(result.body == "")
    }

    @Test func parsesLegacyBlockSequenceTags() throws {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags:
          - swift
          - macOS
        ---

        Body here
        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.tags == ["swift", "macOS"])
        #expect(result.body == "Body here")
    }

    @Test func parsesLegacyBlockTagsWithoutClosingDelimiter() throws {
        let content = """
        ---
        tags:
        - remote-ide
        - claude
        uid: 12345678-1234-1234-1234-123456789ABC
        """
        let result = try #require(FrontmatterParser.parse(content))
        #expect(result.uid == sampleUID)
        #expect(result.tags == ["remote-ide", "claude"])
        #expect(result.body == "")
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

    @Test func roundTripPreservesData() throws {
        let tags = ["swift", "macOS", "mcp"]
        let body = "# Title\n\nSome markdown **content**."
        let serialized = FrontmatterParser.serialize(uid: sampleUID, tags: tags, body: body)
        let parsed = try #require(FrontmatterParser.parse(serialized))
        #expect(parsed.uid == sampleUID)
        #expect(parsed.tags == tags)
        #expect(parsed.body == body)
    }

    @Test func roundTripWithEmptyTags() throws {
        let serialized = FrontmatterParser.serialize(uid: sampleUID, tags: [], body: "")
        let parsed = try #require(FrontmatterParser.parse(serialized))
        #expect(parsed.tags == [])
        #expect(parsed.body == "")
    }
}

// MARK: - NoteFilenameValidator

@Suite("NoteFilenameValidator")
struct NoteFilenameValidatorTests {

    @Test func validName() {
        #expect(NoteFilenameValidator.validate("My Note") == .valid)
    }

    @Test func emptyString() {
        #expect(NoteFilenameValidator.validate("") == .empty)
    }

    @Test func whitespaceOnly() {
        #expect(NoteFilenameValidator.validate("   ") == .empty)
    }

    @Test func exactlyMaxLength() {
        let name = String(repeating: "a", count: NoteFilenameValidator.maxLength)
        #expect(NoteFilenameValidator.validate(name) == .valid)
    }

    @Test func exceedsMaxLength() {
        let name = String(repeating: "a", count: NoteFilenameValidator.maxLength + 1)
        #expect(NoteFilenameValidator.validate(name) == .tooLong)
    }

    @Test("forbidden character is rejected", arguments: [
        "my/note", "note:title", "note*", "note\"title", "note\\title", "note\0title",
    ])
    func forbiddenCharacterRejected(input: String) {
        #expect(NoteFilenameValidator.validate(input) == .forbiddenCharacter)
    }

    @Test func trailingWhitespaceDoesNotMakeItEmpty() {
        #expect(NoteFilenameValidator.validate("  note  ") == .valid)
    }
}
