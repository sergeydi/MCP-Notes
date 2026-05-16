import Foundation
import Testing
@testable import mcpnotes_mac

@Suite("NoteIndexer – loadFromDisk", .timeLimit(.minutes(5)))
struct NoteIndexerLoadFromDiskTests {

    func makeNote(filename: String, body: String) -> Note {
        Note(
            id: UUID(),
            filename: filename,
            tags: [],
            body: body,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"),
            isBookmarked: false
        )
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
}
