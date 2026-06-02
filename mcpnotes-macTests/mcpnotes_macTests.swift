import Foundation
import Testing
@testable import MCPNotesCore
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

    @Test func parsesLegacyFormatWithoutClosingDelimiter() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags: []
        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.uid == sampleUID)
        #expect(result?.tags == [])
        #expect(result?.body == "")
    }

    @Test func parsesLegacyBlockSequenceTags() {
        let content = """
        ---
        uid: 12345678-1234-1234-1234-123456789ABC
        tags:
          - swift
          - macOS
        ---

        Body here
        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.tags == ["swift", "macOS"])
        #expect(result?.body == "Body here")
    }

    @Test func parsesLegacyBlockTagsWithoutClosingDelimiter() {
        let content = """
        ---
        tags:
        - remote-ide
        - claude
        uid: 12345678-1234-1234-1234-123456789ABC
        """
        let result = FrontmatterParser.parse(content)
        #expect(result?.uid == sampleUID)
        #expect(result?.tags == ["remote-ide", "claude"])
        #expect(result?.body == "")
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

    @Test func forbiddenCharacterSlash() {
        #expect(NoteFilenameValidator.validate("my/note") == .forbiddenCharacter)
    }

    @Test func forbiddenCharacterColon() {
        #expect(NoteFilenameValidator.validate("note:title") == .forbiddenCharacter)
    }

    @Test func forbiddenCharacterAsterisk() {
        #expect(NoteFilenameValidator.validate("note*") == .forbiddenCharacter)
    }

    @Test func forbiddenCharacterQuote() {
        #expect(NoteFilenameValidator.validate("note\"title") == .forbiddenCharacter)
    }

    @Test func forbiddenCharacterBackslash() {
        #expect(NoteFilenameValidator.validate("note\\title") == .forbiddenCharacter)
    }

    @Test func forbiddenCharacterNull() {
        #expect(NoteFilenameValidator.validate("note\0title") == .forbiddenCharacter)
    }

    @Test func trailingWhitespaceDoesNotMakeItEmpty() {
        #expect(NoteFilenameValidator.validate("  note  ") == .valid)
    }
}
