import CoreML
import CryptoKit
import Embeddings
import Foundation
import SQLite3
import USearch

protocol NoteIndexing {
    func loadFromDisk() async
    func indexedCount() async -> Int
    func indexAll(_ notes: [Note]) async throws
    func indexNote(_ note: Note) async throws
    func removeNote(id: UUID) async
    func clearHashStore() async
    func resetAndClearIndex() async
    func search(query: String, limit: Int) async throws -> [UUID]
    func searchRanked(query: String, limit: Int) async throws -> [(id: UUID, score: Float)]
    func searchBM25Ranked(query: String, limit: Int) async -> [(id: UUID, rank: Int)]
}

/// Manages on-device vector indexing and semantic search for notes.
/// Uses multilingual-e5-small (XLM-RoBERTa) downloaded from HuggingFace Hub on first launch.
/// All data lives in Application Support — never synced to iCloud.
actor NoteIndexer: NoteIndexing {

    // MARK: - Constants

    private nonisolated static let modelID = "intfloat/multilingual-e5-small"
    /// multilingual-e5-small hidden size.
    private nonisolated static let dimensions: UInt32 = 384
    /// Bump when the chunking strategy or index format changes to force a full re-index.
    private nonisolated static let currentIndexVersion = 8
    /// Upper bound on the number of chunk vectors produced per note (filename + tags + paragraphs).
    private nonisolated static let maxChunksPerNote = 20

    // MARK: - State

    private var modelBundle: XLMRoberta.ModelBundle?
    private var modelLoadTask: Task<XLMRoberta.ModelBundle, Error>?
    private var vectorIndex: USearchIndex = .make(metric: .cos, dimensions: 384, connectivity: 16, quantization: .F32)
    /// Maps each note UUID to the keys of all its indexed chunks.
    private var uuidToKeys: [UUID: [UInt64]] = [:]
    private var keyToUUID: [UInt64: UUID] = [:]
    private var nextKey: UInt64 = 1
    private var saveTask: Task<Void, Never>?

    // MARK: - Paths

    private let indexPath: String
    private let db: IndexDatabase

    // MARK: - Init

    init(storageDirectory: URL? = nil) {
        let dir: URL
        if let custom = storageDirectory {
            dir = custom
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            dir = appSupport.appendingPathComponent("mcpnotes/rag", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexPath = dir.appendingPathComponent("notes.usearch").path
        db = IndexDatabase(url: dir.appendingPathComponent("notes-index.db"))
    }

    // MARK: - NoteIndexing

    /// Returns the number of indexed notes (not chunk vectors).
    func indexedCount() async -> Int { uuidToKeys.count }

    // MARK: - Lifecycle

    /// Load persisted index and key mapping. Call once on app launch after NoteStore.load().
    func loadFromDisk() {
        // Try current SQLite format first.
        if let storedVersion = db.intMeta("index_version"),
           storedVersion == Self.currentIndexVersion,
           FileManager.default.fileExists(atPath: indexPath) {
            vectorIndex.load(path: indexPath)
            let capacity = max(UInt32(vectorIndex.count) + 16, 64)
            vectorIndex.reserve(capacity)
            let storedNextKey = UInt64(db.intMeta("next_key") ?? 1)

            // Detect inconsistency: note_chunks has keys beyond what notes.usearch contains.
            // This happens when a previous session was interrupted mid-indexAll().
            // Force a clean re-index by wiping the persisted state.
            let maxChunkKey = db.maxChunkKey() ?? 0
            if maxChunkKey >= storedNextKey {
                vectorIndex = USearchIndex.make(
                    metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                )
                db.clearAll()
                return
            }

            nextKey = storedNextKey
            for uuid in db.allUUIDs() {
                let keys = db.chunkKeys(for: uuid)
                uuidToKeys[uuid] = keys
                for key in keys { keyToUUID[key] = uuid }
            }
            return
        }

        // Fresh start — clear hashes so indexAll() re-indexes everything.
        db.clearHashes()
    }

    /// Persist index and mapping to disk.
    func saveToDisk() {
        saveTask?.cancel()
        saveTask = nil
        vectorIndex.save(path: indexPath)
        db.setMeta("index_version", Self.currentIndexVersion)
        db.setMeta("next_key", Int(nextKey))
    }

    // MARK: - Indexing

    /// Index or re-index a single note. The body is split into paragraphs; each paragraph
    /// becomes a separate vector. Documents use the "passage: " E5 prefix.
    func indexNote(_ note: Note) async throws {
        try await indexNoteCore(note)
        scheduleSave()
    }

    // Core indexing without triggering a save — used by indexAll() to avoid mid-batch saves.
    private func indexNoteCore(_ note: Note) async throws {
        // Remove all existing chunk keys for this note before re-indexing.
        if let oldKeys = uuidToKeys[note.id] {
            for key in oldKeys {
                vectorIndex.remove(key: key)
                keyToUUID.removeValue(forKey: key)
            }
        }
        uuidToKeys[note.id] = []

        let tags = note.tags.isEmpty ? "" : note.tags.joined(separator: " ")
        let cleanBody = NoteIndexer.stripMarkdown(note.body)

        // Metadata as separate chunks: filename, tags (non-empty only).
        let metaChunks = [note.filename, tags].filter { !$0.isEmpty }
        let chunks = metaChunks + NoteIndexer.paragraphs(cleanBody)

        for chunk in chunks {
            let vector = try await embed("passage: \(chunk)")
            let key = nextKey
            nextKey += 1
            uuidToKeys[note.id]!.append(key)
            keyToUUID[key] = note.id
            vectorIndex.add(key: key, vector: vector)
        }

        db.setChunkKeys(uuidToKeys[note.id] ?? [], for: note.id)
        db.setMD5(NoteIndexer.contentHash(for: note), for: note.id)
        let ftsContent = ([note.filename] + note.tags + [cleanBody])
            .filter { !$0.isEmpty }.joined(separator: " ")
        db.insertFTS(uuid: note.id, content: ftsContent)
        db.upsertTags(note.tags, for: note.id)
        db.upsertMeta(filename: note.filename, for: note.id)
    }

    /// Remove a note and all its chunk vectors from the index.
    func removeNote(id: UUID) {
        guard let keys = uuidToKeys[id] else { return }
        for key in keys {
            vectorIndex.remove(key: key)
            keyToUUID.removeValue(forKey: key)
        }
        uuidToKeys.removeValue(forKey: id)
        db.removeChunks(for: id)
        db.removeMD5(for: id)
        db.deleteFTS(uuid: id)
        db.removeTags(for: id)
        db.removeMeta(for: id)
        scheduleSave()
    }

    /// Incrementally sync the index: remove deleted notes, skip unchanged notes,
    /// re-index only new or modified ones.
    func indexAll(_ notes: [Note]) async throws {
        // Remove notes that no longer exist on disk.
        let incomingIDs = Set(notes.map(\.id))
        let staleIDs = uuidToKeys.keys.filter { !incomingIDs.contains($0) }
        for id in staleIDs { removeNote(id: id) }

        // Filter to notes that need (re)indexing.
        let toIndex = notes.filter { note in
            let hash = NoteIndexer.contentHash(for: note)
            // Migrated note: chunk keys exist in memory but MD5 not yet stored.
            // Record the hash and skip re-indexing to preserve the HNSW graph.
            if db.md5(for: note.id) == nil, uuidToKeys[note.id] != nil {
                db.setMD5(hash, for: note.id)
                return false
            }
            return db.md5(for: note.id) != hash
        }
        guard !toIndex.isEmpty else {
            saveToDisk()
            return
        }

        let needed = max(UInt32(vectorIndex.count) + UInt32(toIndex.count * Self.maxChunksPerNote), 64)
        vectorIndex.reserve(needed)

        for note in toIndex {
            try await indexNoteCore(note)
        }
        saveToDisk()
    }

    /// Clear stored MD5 hashes so the next indexAll() re-indexes all notes.
    func clearHashStore() {
        db.clearHashes()
    }

    /// Wipe the entire index. Used before a manual full re-index from Settings.
    func resetAndClearIndex() {
        uuidToKeys = [:]
        keyToUUID = [:]
        nextKey = 1
        vectorIndex = USearchIndex.make(metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32)
        db.clearAll()
    }

    // MARK: - Search

    /// Returns notes ranked by BM25 keyword relevance (rank 1 = best match).
    func searchBM25Ranked(query: String, limit: Int = 10) -> [(id: UUID, rank: Int)] {
        db.searchFTS(query: query, limit: limit)
            .enumerated().map { (id: $0.element.0, rank: $0.offset + 1) }
    }

    /// Returns note UUIDs ranked by semantic similarity, closest first.
    func search(query: String, limit: Int = 10) async throws -> [UUID] {
        try await searchRanked(query: query, limit: limit).map(\.id)
    }

    /// Returns note UUIDs with their best-chunk cosine similarity scores (0–1), highest first.
    func searchRanked(query: String, limit: Int = 10) async throws -> [(id: UUID, score: Float)] {
        guard vectorIndex.count > 0 else { return [] }
        let queryVector = try await embed("query: \(query)")

        // Fetch extra chunk vectors to guarantee enough distinct notes after grouping.
        let (keys, distances) = vectorIndex.search(vector: queryVector, count: limit * 5)

        // Group by note UUID — keep best (highest) chunk score per note.
        var rawScores: [UUID: Float] = [:]
        for (key, distance) in zip(keys, distances) {
            guard let uuid = keyToUUID[key] else { continue }
            let score = 1 - distance
            if (rawScores[uuid] ?? 0) < score {
                rawScores[uuid] = score
            }
        }

        // Trim to top `limit` notes.
        var scores: [UUID: Float] = [:]
        for (uuid, score) in rawScores.sorted(by: { $0.value > $1.value }).prefix(limit) {
            scores[uuid] = score
        }

        return scores.sorted { $0.value > $1.value }.map { (id: $0.key, score: $0.value) }
    }

    // MARK: - Private: embedding

    private func loadedModel() async throws -> XLMRoberta.ModelBundle {
        if let bundle = modelBundle { return bundle }
        if let task = modelLoadTask { return try await task.value }
        let task = Task { try await XLMRoberta.loadModelBundle(from: Self.modelID) }
        modelLoadTask = task
        do {
            let bundle = try await task.value
            modelBundle = bundle
            modelLoadTask = nil
            return bundle
        } catch {
            modelLoadTask = nil
            throw error
        }
    }

    /// Embed text using mean pooling + L2 normalization (E5 recipe).
    private func embed(_ text: String) async throws -> [Float] {
        let bundle = try await loadedModel()
        let tokens = try bundle.tokenizer.tokenizeText(text, maxLength: 512)
        let seqLen = tokens.count
        let inputIds = MLTensor(shape: [1, seqLen], scalars: tokens)
        let attentionMask = MLTensor(ones: [1, seqLen], scalarType: Float32.self)
        let output = bundle.model(inputIds: inputIds, attentionMask: attentionMask)
        // Mean pool over the sequence dimension: [1, seq_len, 384] → [1, 384]
        let pooled = output.sequenceOutput.mean(alongAxes: 1, keepRank: false)
        var vector = await pooled.cast(to: Float.self).shapedArray(of: Float.self).scalars
        // L2 normalize so cosine similarity equals dot product
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { vector = vector.map { $0 / norm } }
        return vector
    }

    // MARK: - Private: chunking

    /// Split markdown-stripped body into non-empty paragraphs.
    private nonisolated static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Private: markdown stripping

    nonisolated static func stripMarkdown(_ text: String) -> String {
        var s = text
        // Code fence markers — keep code content, remove ``` lines
        s = s.replacing(/(?m)^```[^\n]*$/, with: "")
        // Inline code — keep content, remove backticks
        s = s.replacing(/`([^`\n]+)`/) { $0.output.1 }
        s = s.replacing(/`/, with: "")
        // ATX headings
        s = s.replacing(#/(?m)^#{1,6} /#, with: "")
        // Task list markers - [ ] / - [x]
        s = s.replacing(#/(?m)^- \[[ xX]\] /#, with: "")
        // Bold **text** / __text__
        s = s.replacing(/\*\*([^*\n]+)\*\*/) { $0.output.1 }
        s = s.replacing(/__([^_\n]+)__/) { $0.output.1 }
        // Italic *text* / _text_
        s = s.replacing(/\*([^*\n]+)\*/) { $0.output.1 }
        s = s.replacing(/_([^_\n]+)_/) { $0.output.1 }
        // Strikethrough ~~text~~
        s = s.replacing(/~~([^~\n]+)~~/) { $0.output.1 }
        // Images — remove entirely
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        // Markdown links [text](url) → text
        s = s.replacing(/\[([^\]]+)\]\([^)]*\)/) { $0.output.1 }
        // Wikilinks [[Name]] → Name
        s = s.replacing(/\[\[([^\]]+)\]\]/) { $0.output.1 }
        // Blockquotes
        s = s.replacing(/(?m)^> ?/, with: "")
        // Horizontal rules
        s = s.replacing(/(?m)^[-*_]{3,}\s*$/, with: "")
        // HTML tags
        s = s.replacing(/<[^>]+>/, with: "")
        return s
    }

    // MARK: - Private: deferred save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.performDeferredSave()
        }
    }

    private func performDeferredSave() async {
        saveToDisk()
    }

    // MARK: - Private: content hash

    private nonisolated static func contentHash(for note: Note) -> String {
        let raw = note.body + note.tags.sorted().joined()
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - IndexDatabase

/// SQLite-backed store for chunk-key mappings and per-note content hashes.
/// Replaces notes-keys.json; lives alongside notes.usearch in Application Support.
private final class IndexDatabase: @unchecked Sendable {
    nonisolated(unsafe) private var db: OpaquePointer?
    private nonisolated let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        sqlite3_open_v2(url.path, &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS note_chunks (
                uuid      TEXT    NOT NULL,
                chunk_key INTEGER NOT NULL,
                PRIMARY KEY (uuid, chunk_key)
            );
            CREATE TABLE IF NOT EXISTS file_hashes (
                uuid TEXT PRIMARY KEY,
                md5  TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                uuid UNINDEXED,
                content,
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS note_tags (
                uuid TEXT NOT NULL,
                tag  TEXT NOT NULL,
                PRIMARY KEY (uuid, tag)
            );
            CREATE TABLE IF NOT EXISTS note_meta (
                uuid     TEXT PRIMARY KEY,
                filename TEXT NOT NULL
            );
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    // MARK: meta

    nonisolated func intMeta(_ key: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    nonisolated func setMeta(_ key: String, _ value: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_int64(stmt, 2, Int64(value))
        sqlite3_step(stmt)
    }

    // MARK: note_chunks

    nonisolated func chunkKeys(for uuid: UUID) -> [UInt64] {
        var stmt: OpaquePointer?
        let uuidStr = uuid.uuidString
        guard sqlite3_prepare_v2(db, "SELECT chunk_key FROM note_chunks WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuidStr, -1, transient)
        var keys: [UInt64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            keys.append(UInt64(bitPattern: sqlite3_column_int64(stmt, 0)))
        }
        return keys
    }

    nonisolated func allUUIDs() -> Set<UUID> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT uuid FROM note_chunks", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var uuids: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr)) {
                uuids.insert(uuid)
            }
        }
        return uuids
    }

    nonisolated func setChunkKeys(_ keys: [UInt64], for uuid: UUID) {
        let uuidStr = uuid.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM note_chunks WHERE uuid = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, uuidStr, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO note_chunks (uuid, chunk_key) VALUES (?, ?)", -1, &insStmt, nil) == SQLITE_OK {
            for key in keys {
                sqlite3_bind_text(insStmt, 1, uuidStr, -1, transient)
                sqlite3_bind_int64(insStmt, 2, Int64(bitPattern: key))
                sqlite3_step(insStmt)
                sqlite3_reset(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func removeChunks(for uuid: UUID) {
        var stmt: OpaquePointer?
        let uuidStr = uuid.uuidString
        guard sqlite3_prepare_v2(db, "DELETE FROM note_chunks WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuidStr, -1, transient)
        sqlite3_step(stmt)
    }

    // MARK: file_hashes

    nonisolated func md5(for uuid: UUID) -> String? {
        var stmt: OpaquePointer?
        let uuidStr = uuid.uuidString
        guard sqlite3_prepare_v2(db, "SELECT md5 FROM file_hashes WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuidStr, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    nonisolated func setMD5(_ md5: String, for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO file_hashes (uuid, md5) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, md5, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func removeMD5(for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM file_hashes WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func clearHashes() {
        sqlite3_exec(db, "DELETE FROM file_hashes", nil, nil, nil)
    }

    nonisolated func maxChunkKey() -> UInt64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(chunk_key) FROM note_chunks", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let raw = sqlite3_column_int64(stmt, 0)
        return raw == 0 ? nil : UInt64(bitPattern: raw)
    }

    // MARK: notes_fts

    nonisolated func insertFTS(uuid: UUID, content: String) {
        let uuidStr = uuid.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM notes_fts WHERE uuid = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, uuidStr, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO notes_fts(uuid, content) VALUES (?, ?)", -1, &insStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(insStmt, 1, uuidStr, -1, transient)
            sqlite3_bind_text(insStmt, 2, content, -1, transient)
            sqlite3_step(insStmt)
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func deleteFTS(uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM notes_fts WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func clearFTS() {
        sqlite3_exec(db, "DELETE FROM notes_fts", nil, nil, nil)
    }

    // MARK: note_tags

    nonisolated func upsertTags(_ tags: [String], for uuid: UUID) {
        let uuidStr = uuid.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM note_tags WHERE uuid = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, uuidStr, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO note_tags (uuid, tag) VALUES (?, ?)", -1, &insStmt, nil) == SQLITE_OK {
            for tag in tags {
                sqlite3_bind_text(insStmt, 1, uuidStr, -1, transient)
                sqlite3_bind_text(insStmt, 2, tag, -1, transient)
                sqlite3_step(insStmt)
                sqlite3_reset(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func removeTags(for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM note_tags WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    // MARK: note_meta

    nonisolated func upsertMeta(filename: String, for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO note_meta (uuid, filename) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, filename, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func removeMeta(for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM note_meta WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func searchFTS(query: String, limit: Int) -> [(UUID, Double)] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT uuid, bm25(notes_fts) FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts) LIMIT ?",
            -1, &stmt, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sanitized, -1, transient)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var results: [(UUID, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: cStr)) else { continue }
            results.append((uuid, sqlite3_column_double(stmt, 1)))
        }
        return results
    }

    private nonisolated func sanitizeFTSQuery(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !"\"*()-^:\\".contains(Character($0)) }
        return String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated func clearAll() {
        sqlite3_exec(db,
            "DELETE FROM note_chunks; DELETE FROM file_hashes; DELETE FROM meta; DELETE FROM notes_fts; DELETE FROM note_tags; DELETE FROM note_meta",
            nil, nil, nil)
    }
}
