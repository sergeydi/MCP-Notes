import Foundation

public protocol NoteIndexing {
    /// Load persisted index. Returns `true` if the index was corrupted or inconsistent
    /// and had to be reset (triggering a full re-index), `false` on a normal load or fresh start.
    func loadFromDisk() async -> Bool
    func indexedCount() async -> Int
    func indexAll(_ notes: [Note]) async throws
    func indexNote(_ note: Note) async throws
    func indexNoteIfChanged(_ note: Note) async throws
    func removeNote(id: UUID) async
    func clearHashStore() async
    func resetAndClearIndex() async
    func search(query: String, limit: Int) async throws -> [UUID]
    func searchRanked(query: String, limit: Int) async throws -> [(id: UUID, score: Float)]
    func searchBM25Ranked(query: String, limit: Int) async -> [(id: UUID, rank: Int)]
    func outgoingLinks(from noteID: UUID) async -> [UUID]
    func incomingLinks(to noteID: UUID) async -> [UUID]
    func allLinks() async -> [(source: UUID, target: UUID)]
}
