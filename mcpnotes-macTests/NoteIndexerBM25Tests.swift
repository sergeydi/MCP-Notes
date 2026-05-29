import Foundation
import Testing
@testable import MCPNotesCore
@testable import mcpnotes_mac

@Suite("NoteIndexer – BM25 search", .timeLimit(.minutes(5)))
struct NoteIndexerBM25Tests {

    private func makeNote(filename: String, body: String, tags: [String] = []) -> Note {
        Note(id: UUID(), filename: filename, tags: tags, body: body,
             fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"), isBookmarked: false)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("BM25 returns exact keyword match as first result")
    func bm25ReturnsKeywordMatch() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let swift = makeNote(filename: "Swift", body: "Swift actors and structured concurrency.")
        let recipe = makeNote(filename: "Pasta", body: "Boil water and add tomato sauce to spaghetti.")
        try await indexer.indexAll([swift, recipe])
        let results = await indexer.searchBM25Ranked(query: "tomato sauce spaghetti", limit: 5)
        #expect(results.first?.id == recipe.id)
    }

    @Test("BM25 returns empty for operator-only query")
    func bm25EmptyForOperatorOnlyQuery() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let note = makeNote(filename: "Note", body: "Some content here.")
        try await indexer.indexAll([note])
        let results = await indexer.searchBM25Ranked(query: "***---", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("removeNote removes its FTS entry")
    func removeNoteRemovesFTSEntry() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let note = makeNote(filename: "Removable", body: "unique-keyword-xyzzy content")
        try await indexer.indexAll([note])
        await indexer.removeNote(id: note.id)
        let results = await indexer.searchBM25Ranked(query: "unique-keyword-xyzzy", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("re-indexing updates FTS content")
    func reindexUpdatesFTSContent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let id = UUID()
        let original = Note(id: id, filename: "Note", tags: [], body: "cooking pasta tomato",
                            fileURL: URL(fileURLWithPath: "/tmp/Note.md"), isBookmarked: false)
        let updated = Note(id: id, filename: "Note", tags: [], body: "swift concurrency actors",
                           fileURL: URL(fileURLWithPath: "/tmp/Note.md"), isBookmarked: false)
        try await indexer.indexAll([original])
        try await indexer.indexNote(updated)
        let oldResults = await indexer.searchBM25Ranked(query: "tomato pasta", limit: 5)
        #expect(oldResults.first?.id != id)
        let newResults = await indexer.searchBM25Ranked(query: "swift actors", limit: 5)
        #expect(newResults.first?.id == id)
    }
}
