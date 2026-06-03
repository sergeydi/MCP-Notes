import Foundation
import Testing
@testable import MCPNotesCore
@testable import mcpnotes_mac

@Suite("NoteIndexer – loadFromDisk", .serialized, .timeLimit(.minutes(5)))
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
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Regression Note", body: "USearch thread slot regression test.")

        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([note])

        let indexerB = NoteIndexer(storageDirectory: tmp)
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

        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([kept, deleted])

        // App restarts; "deleted" was removed from disk while the app was closed.
        let indexerB = NoteIndexer(storageDirectory: tmp)
        let recovered = await indexerB.loadFromDisk()
        #expect(recovered == false, "Normal restart must not signal recovery")
        try await indexerB.indexAll([kept])

        #expect(await indexerB.indexedCount() == 1)
        let results = try await indexerB.search(query: "Ancient Roman history empire", limit: 5)
        #expect(results.contains(deleted.id) == false, "Note deleted while app was closed must not appear in search after restart")
    }

    @Test("note modified while app was closed returns new content after restart")
    func modifiedNoteReturnsNewContentAfterRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteID = UUID()
        let original = makeNote(id: noteID, filename: "Note", body: "Astronomy telescope stargazing and night sky observation.")
        let modified = makeNote(id: noteID, filename: "Note", body: "Machine learning neural networks and deep learning architectures.")

        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([original])

        // App restarts; the note body was edited while the app was closed.
        let indexerB = NoteIndexer(storageDirectory: tmp)
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

        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([note])

        // Overwrite the usearch file with garbage to simulate corruption.
        let usearchURL = tmp.appendingPathComponent("notes.usearch")
        try Data(repeating: 0xFF, count: 512).write(to: usearchURL)

        // loadFromDisk must not crash, must silently reset, and must signal recovery.
        let indexerB = NoteIndexer(storageDirectory: tmp)
        let recovered = await indexerB.loadFromDisk()

        #expect(recovered == true, "loadFromDisk must return true when the usearch file is corrupted")
        #expect(await indexerB.indexedCount() == 0, "After corrupted usearch, index should be empty")

        // New notes must be indexable after recovery.
        let newNote = makeNote(filename: "Recovery", body: "Indexing works again after corruption recovery.")
        try await indexerB.indexNote(newNote)
        let results = try await indexerB.search(query: "corruption recovery", limit: 1)
        #expect(results.first == newNote.id, "New note must be searchable after corruption recovery")
    }

    @Test("note added while app was closed is searchable after restart")
    func addedNoteSearchableAfterRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let existing = makeNote(filename: "Cooking", body: "Italian cuisine pasta recipes.")
        let added = makeNote(filename: "Physics", body: "Quantum physics and particle accelerator experiments.")

        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([existing])

        // App restarts; a new note was created while the app was closed.
        let indexerB = NoteIndexer(storageDirectory: tmp)
        await indexerB.loadFromDisk()
        try await indexerB.indexAll([existing, added])

        #expect(await indexerB.indexedCount() == 2)
        let results = try await indexerB.search(query: "quantum physics particle accelerator", limit: 1)
        #expect(results.first == added.id, "Note added while app was closed must be searchable after restart")
    }
}
