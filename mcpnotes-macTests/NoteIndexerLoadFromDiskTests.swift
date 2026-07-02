import Foundation
import Testing
@testable import MCPNotesCore
@testable import mcpnotes_mac

extension NoteIndexerTests {
@Suite("NoteIndexer – loadFromDisk", .serialized)
struct NoteIndexerLoadFromDiskTests {

    func makeNote(id: UUID = UUID(), filename: String, body: String) -> Note {
        Note(
            id: id,
            filename: filename,
            tags: [],
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

    /// Regression: vectorIndex.add() crashed after loadFromDisk because USearch does not
    /// persist thread-slot structures to disk. reserve() must be called after load().
    @Test("indexNote does not crash after loadFromDisk (thread-slot regression)")
    func indexNoteAfterLoadFromDiskDoesNotCrash() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Regression Note", body: "USearch thread slot regression test.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([note])

        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        await indexerB.loadFromDisk()

        let updated = makeNote(filename: note.filename, body: "Updated body after reload.")
        try await indexerB.indexNote(updated)

        let results = try await indexerB.search(query: "updated reload", limit: 1)
        #expect(results.isEmpty == false, "Note indexed after loadFromDisk should be searchable")
    }

    @Test("note deleted while app was closed is not searchable after restart")
    func deletedNoteNotSearchableAfterRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kept = makeNote(filename: "Cooking", body: "Italian cuisine pasta recipes and culinary techniques.")
        let deleted = makeNote(filename: "History", body: "Ancient Roman history and the fall of the empire.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([kept, deleted])

        // App restarts; "deleted" was removed from disk while the app was closed.
        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        let recovered = await indexerB.loadFromDisk()
        #expect(recovered == false, "Normal restart must not signal recovery")
        try await indexerB.indexAll([kept])

        #expect(await indexerB.indexedCount() == 1)
        let results = await indexerB.searchBM25Ranked(query: "Ancient Roman history empire", limit: 5)
        #expect(results.contains { $0.id == deleted.id } == false, "Note deleted while app was closed must not appear in search after restart")
    }

    @Test("note modified while app was closed returns new content after restart")
    func modifiedNoteReturnsNewContentAfterRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteID = UUID()
        let original = makeNote(id: noteID, filename: "Note", body: "Astronomy telescope stargazing and night sky observation.")
        let modified = makeNote(id: noteID, filename: "Note", body: "Machine learning neural networks and deep learning architectures.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([original])

        // App restarts; the note body was edited while the app was closed.
        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        await indexerB.loadFromDisk()
        try await indexerB.indexAll([modified])

        let results = try await indexerB.search(query: "machine learning neural networks", limit: 1)
        #expect(results.first == noteID, "Modified note must rank first for its new content after restart")
    }

    @Test("corrupted usearch file is recovered gracefully on loadFromDisk")
    func corruptedUsearchFileIsRecoveredGracefully() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Hello", body: "Note indexed before corruption.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([note])

        // Overwrite the usearch file with garbage to simulate corruption.
        let usearchURL = tmp.appendingPathComponent("notes.usearch")
        try Data(repeating: 0xFF, count: 512).write(to: usearchURL)

        // loadFromDisk must not crash, must silently reset, and must signal recovery.
        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        let recovered = await indexerB.loadFromDisk()

        #expect(recovered == true, "loadFromDisk must return true when the usearch file is corrupted")
        #expect(await indexerB.indexedCount() == 0, "After corrupted usearch, index should be empty")

        // New notes must be indexable after recovery.
        let newNote = makeNote(filename: "Recovery", body: "Indexing works again after corruption recovery.")
        try await indexerB.indexNote(newNote)
        let results = try await indexerB.search(query: "corruption recovery", limit: 1)
        #expect(results.first == newNote.id, "New note must be searchable after corruption recovery")
    }

    /// Regression: all notes deleted while app runs → 3-second debounced save fires → usearch
    /// saved with 0 active vectors but a stale HNSW entry-point. On the next cold start with
    /// notes restored, vectorIndex.add() threw an uncatchable NSException.
    @Test("cold start survives after all-deleted usearch file was saved")
    func coldStartAfterAllDeletedUsearchDoesNotCrash() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteA = makeNote(filename: "CrashNote1", body: "Unique term zephyr1 content for crash regression test.")
        let noteB = makeNote(filename: "CrashNote2", body: "Unique term zephyr2 content for crash regression test.")
        let noteC = makeNote(filename: "CrashNote3", body: "Unique term zephyr3 content for crash regression test.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([noteA, noteB, noteC])

        // Simulate: all notes removed while app was running, deferred save fired before quit.
        await indexerA.removeNote(id: noteA.id)
        await indexerA.removeNote(id: noteB.id)
        await indexerA.removeNote(id: noteC.id)
        await indexerA.saveToDisk()

        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        let recovered = await indexerB.loadFromDisk()
        #expect(recovered == true, "loadFromDisk must signal recovery for an all-deleted usearch")
        #expect(await indexerB.indexedCount() == 0)

        try await indexerB.indexAll([noteA, noteB, noteC])
        #expect(await indexerB.indexedCount() == 3)
        let expectedID = noteA.id
        let results = await indexerB.searchBM25Ranked(query: "zephyr1 crash regression", limit: 1)
        #expect(results.first?.id == expectedID)
    }

    /// Regression: all notes deleted while app runs → app quit before the 3-second deferred save
    /// → usearch file retains the original N active vectors while note_chunks was cleared.
    /// On the next cold start, the stale usearch/DB mismatch was not detected.
    @Test("cold start survives when usearch has stale vectors and DB was cleared")
    func coldStartWithStaleUsearchAndEmptyDBDoesNotCrash() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteA = makeNote(filename: "StaleNote1", body: "Unique term quasar1 stale vector regression test.")
        let noteB = makeNote(filename: "StaleNote2", body: "Unique term quasar2 stale vector regression test.")
        let noteC = makeNote(filename: "StaleNote3", body: "Unique term quasar3 stale vector regression test.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([noteA, noteB, noteC])

        // Simulate "app quit before deferred save": removeNote clears SQLite synchronously
        // (note_chunks, file_hashes, etc.) but only schedules the usearch save after 3 seconds.
        // We proceed immediately so the usearch file on disk still has N active vectors from
        // indexAll's saveToDisk, creating the stale-usearch / empty-DB inconsistency.
        await indexerA.removeNote(id: noteA.id)
        await indexerA.removeNote(id: noteB.id)
        await indexerA.removeNote(id: noteC.id)

        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        let recovered = await indexerB.loadFromDisk()
        #expect(recovered == true, "loadFromDisk must signal recovery when usearch has stale vectors but DB is empty")
        #expect(await indexerB.indexedCount() == 0)

        try await indexerB.indexAll([noteA, noteB, noteC])
        #expect(await indexerB.indexedCount() == 3)
        let expectedID = noteB.id
        let results = await indexerB.searchBM25Ranked(query: "quasar2 stale vector", limit: 1)
        #expect(results.first?.id == expectedID)
    }

    @Test("partial deletion before debounced save is applied without full re-index on restart")
    func partialDeletionBeforeDebounceIsRecoveredOnRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteA = makeNote(filename: "PartialA", body: "Unique term nebula1 partial orphan regression test.")
        let noteB = makeNote(filename: "PartialB", body: "Unique term nebula2 partial orphan regression test.")
        let noteC = makeNote(filename: "PartialC", body: "Unique term nebula3 partial orphan regression test.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([noteA, noteB, noteC])

        // Simulate "app quit before deferred save": removeNote clears SQLite synchronously and
        // records pending removes, but does not update the usearch file on disk.
        await indexerA.removeNote(id: noteC.id)

        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        let recovered = await indexerB.loadFromDisk()
        // Pending removes are applied in place — no full re-index needed.
        #expect(recovered == false, "loadFromDisk must apply pending removes without triggering full recovery")
        #expect(await indexerB.indexedCount() == 2, "noteA and noteB remain indexed after pending removes applied")

        // noteA and noteB must be searchable without calling indexAll.
        let resultsA = await indexerB.searchBM25Ranked(query: "nebula1 partial orphan", limit: 1)
        #expect(resultsA.first?.id == noteA.id, "noteA must be searchable after pending removes applied")

        // noteC's FTS entry was deleted synchronously by removeNote() — must not appear.
        let resultsC = await indexerB.searchBM25Ranked(query: "nebula3 partial orphan", limit: 5)
        #expect(resultsC.contains { $0.id == noteC.id } == false, "noteC must not be searchable after its vectors were removed")
    }

    @Test("note added while app was closed is searchable after restart")
    func addedNoteSearchableAfterRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let existing = makeNote(filename: "Cooking", body: "Italian cuisine pasta recipes.")
        let added = makeNote(filename: "Physics", body: "Quantum physics and particle accelerator experiments.")

        let indexerA = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        try await indexerA.indexAll([existing])

        // App restarts; a new note was created while the app was closed.
        let indexerB = NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())
        await indexerB.loadFromDisk()
        try await indexerB.indexAll([existing, added])

        #expect(await indexerB.indexedCount() == 2)
        let results = await indexerB.searchBM25Ranked(query: "quantum physics particle accelerator", limit: 1)
        #expect(results.first?.id == added.id, "Note added while app was closed must be searchable after restart")
    }
}
}
