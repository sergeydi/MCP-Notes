import Foundation
import Testing
@testable import mcpnotes_app

extension NoteIndexerTests {
@Suite("NoteIndexer – incremental sync", .serialized, .timeLimit(.minutes(2)))
struct NoteIndexerIncrementalSyncTests {

    func makeNote(id: UUID = UUID(), filename: String, body: String, tags: [String] = []) -> Note {
        Note(
            id: id,
            filename: filename,
            tags: tags,
            body: body,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"),
            isBookmarked: false
        )
    }

    func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("unchanged note is skipped on second indexAll")
    func unchangedNoteSkippedOnReindex() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Unchanged", body: "Swift programming language for macOS.")
        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexAll([note])
        let countAfterFirst = await indexer.indexedCount()

        try await indexer.indexAll([note])
        let countAfterSecond = await indexer.indexedCount()

        #expect(countAfterFirst == 1)
        #expect(countAfterSecond == 1)
        let results = try await indexer.search(query: "Swift macOS programming", limit: 1)
        #expect(results.first == note.id)
    }

    @Test("changed note is re-indexed after content update via indexAll")
    func changedNoteReindexedAfterContentUpdate() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = UUID()
        let original = makeNote(id: id, filename: "My Note", body: "Pasta recipe with tomato sauce.")
        let updated = makeNote(id: id, filename: "My Note", body: "Swift actors and structured concurrency.")

        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexAll([original])
        try await indexer.indexAll([updated])

        let results = try await indexer.search(query: "Swift concurrency actors", limit: 1)
        #expect(results.first == id, "Note should rank first for new content after re-index")
    }

    @Test("note missing from indexAll list is removed from search results")
    func deletedNoteRemovedOnIndexAll() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kept = makeNote(filename: "Kept", body: "Gardening and composting tips for spring.")
        let removed = makeNote(filename: "Removed", body: "Swift programming with generics and protocols.")

        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexAll([kept, removed])
        try await indexer.indexAll([kept])

        let count = await indexer.indexedCount()
        #expect(count == 1)
        let results = try await indexer.search(query: "Swift generics protocols", limit: 5)
        #expect(results.contains(removed.id) == false, "Removed note must not appear in results")
    }

    @Test("resetAndClearIndex empties the vector index and makes search return empty")
    func resetAndClearIndexEmptiesIndex() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Note", body: "Swift language features and protocols.")
        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexAll([note])
        #expect(await indexer.indexedCount() == 1)

        await indexer.resetAndClearIndex()

        #expect(await indexer.indexedCount() == 0)
        let results = try await indexer.search(query: "Swift language", limit: 5)
        #expect(results.isEmpty, "Search must return empty after reset")
    }

    @Test("indexNoteIfChanged skips note when body and tags are unchanged")
    func indexNoteIfChangedSkipsUnchangedNote() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Note", body: "Swift programming language for macOS.")
        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexNote(note)

        // Second call with same content must be a no-op: index still searchable, no double-vectors.
        try await indexer.indexNoteIfChanged(note)
        let count = await indexer.indexedCount()
        #expect(count == 1)
        let results = try await indexer.search(query: "Swift macOS programming", limit: 1)
        #expect(results.first == note.id)
    }

    @Test("indexNoteIfChanged re-indexes note when body changes")
    func indexNoteIfChangedReindexesChangedBody() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = UUID()
        let original = makeNote(id: id, filename: "Note", body: "Pasta recipe with tomato sauce.")
        let updated  = makeNote(id: id, filename: "Note", body: "Swift actors and structured concurrency.")
        // Decoy note stays in the index with pasta content, making the negative assertion meaningful:
        // after re-indexing `id` to Swift content, pasta query must prefer the decoy over `id`.
        let decoy = makeNote(filename: "Decoy", body: "Italian pasta with tomato and basil sauce.")
        let indexer = NoteIndexer(storageDirectory: tmp)
        try await indexer.indexNote(original)
        try await indexer.indexNote(decoy)
        try await indexer.indexNoteIfChanged(updated)

        let newResults = try await indexer.search(query: "Swift concurrency actors", limit: 1)
        #expect(newResults.first == id, "Updated content must be searchable after indexNoteIfChanged")
        let oldResults = try await indexer.search(query: "Pasta tomato sauce", limit: 1)
        #expect(oldResults.first != id, "Old content must no longer rank first after re-index")
    }

    @Test("indexNoteIfChanged skips note whose body was already indexed via indexAll")
    func indexNoteIfChangedSkipsNoteAlreadyIndexedByIndexAll() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Note", body: "Gardening tips for spring and autumn.")
        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexAll([note])
        let countBefore = await indexer.indexedCount()

        try await indexer.indexNoteIfChanged(note)
        let countAfter = await indexer.indexedCount()
        #expect(countBefore == countAfter)
    }

    @Test("indexNoteIfChanged re-indexes note when only filename changes")
    func indexNoteIfChangedReindexesRenamedNote() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = UUID()
        let original = makeNote(id: id, filename: "OldName", body: "Structured concurrency in Swift.")
        let renamed  = makeNote(id: id, filename: "NewName", body: "Structured concurrency in Swift.")

        let indexer = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexer.indexNote(original)
        try await indexer.indexNoteIfChanged(renamed)

        let count = await indexer.indexedCount()
        #expect(count == 1, "Переименование не должно создавать дубль в индексе")

        let bm25New = await indexer.searchBM25Ranked(query: "NewName", limit: 5)
        #expect(bm25New.contains { $0.id == id }, "Заметка должна находиться по новому имени")

        let bm25Old = await indexer.searchBM25Ranked(query: "OldName", limit: 5)
        #expect(!bm25Old.contains { $0.id == id }, "Старое имя не должно совпадать после переименования")
    }

    @Test("clearHashStore forces re-index on fresh indexer without loadFromDisk")
    func clearHashStoreTriggersReindexOnFreshStart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Note", body: "Swift programming language for iOS.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([note])

        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        await indexerB.clearHashStore()
        try await indexerB.indexAll([note])

        let results = try await indexerB.search(query: "Swift iOS programming", limit: 1)
        #expect(results.first == note.id, "Note must be indexed and searchable after clearHashStore + indexAll")
    }
}
}
