import Foundation

/// No-op `NoteIndexing` conformance used on platforms (iOS) where the RAG/FTS index,
/// its SQLite/USearch storage, and the embeddings XPC service are not available.
actor NoOpNoteIndexer: NoteIndexing {
    func loadFromDisk() async -> Bool { false }
    func indexedCount() async -> Int { 0 }
    func indexAll(_ notes: [Note]) async throws {}
    func indexNote(_ note: Note) async throws {}
    func indexNoteIfChanged(_ note: Note) async throws {}
    func allIndexedIDs() async -> Set<UUID> { [] }
    func removeNote(id: UUID) async {}
    func clearHashStore() async {}
    func resetAndClearIndex() async {}
    func search(query: String, limit: Int) async throws -> [UUID] { [] }
    func searchRanked(query: String, limit: Int) async throws -> [(id: UUID, score: Float)] { [] }
    func searchBM25Ranked(query: String, limit: Int) async -> [(id: UUID, rank: Int)] { [] }
    func outgoingLinks(from noteID: UUID) async -> [UUID] { [] }
    func incomingLinks(to noteID: UUID) async -> [UUID] { [] }
    func allLinks() async -> [(source: UUID, target: UUID)] { [] }
}
