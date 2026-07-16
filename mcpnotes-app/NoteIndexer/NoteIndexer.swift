import CryptoKit
import Foundation
import USearch

/// Manages on-device vector indexing and semantic search for notes.
/// Uses multilingual-e5-small (XLM-RoBERTa) downloaded from HuggingFace Hub on first launch.
/// All data lives in Application Support — never synced to iCloud.
actor NoteIndexer: NoteIndexing {

    // MARK: - Constants

    /// multilingual-e5-small hidden size.
    private nonisolated static let dimensions: UInt32 = 384
    /// Bump when the chunking strategy or index format changes to force a full re-index.
    private nonisolated static let currentIndexVersion = 8
    /// Upper bound on the number of chunk vectors produced per note (filename + tags + paragraphs).
    private nonisolated static let maxChunksPerNote = 20

    // MARK: - State

    private let embedder: any NoteEmbedding
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

    init(storageDirectory: URL? = nil, embedder: (any NoteEmbedding)? = nil) {
        self.embedder = embedder ?? XPCNoteEmbedder()
        let dir: URL
        if let custom = storageDirectory {
            dir = custom
        } else {
            let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.mcp-notes")
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = base.appendingPathComponent("mcpnotes/rag", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexPath = dir.appendingPathComponent("notes.usearch").path
        db = IndexDatabase(url: dir.appendingPathComponent("notes-index.db"))
        vectorIndex.reserve(64)
    }

    // MARK: - NoteIndexing

    /// Returns the number of indexed notes (not chunk vectors).
    func indexedCount() async -> Int { uuidToKeys.count }

    func allIndexedIDs() async -> Set<UUID> { Set(uuidToKeys.keys) }

    // MARK: - Lifecycle

    /// Load persisted index and key mapping. Call once on app launch after NoteStore.load().
    /// Returns `true` if the index was corrupted or inconsistent and had to be reset.
    @discardableResult
    func loadFromDisk() async -> Bool {
        // Try current SQLite format first.
        if let storedVersion = db.intMeta("index_version"),
           storedVersion == Self.currentIndexVersion,
           FileManager.default.fileExists(atPath: indexPath) {
            let storedNextKey = UInt64(db.intMeta("next_key") ?? 1)

            // If the dirty flag is set, the previous save was interrupted mid-write (e.g. by
            // an uncaught NSException from USearch). The .usearch file may be corrupt — reset.
            if db.intMeta("index_dirty") == 1 {
                vectorIndex = USearchIndex.make(
                    metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                )
                vectorIndex.reserve(64)
                db.clearAll()
                return true
            }

            // Validate the usearch file header BEFORE loading. USearch's load() throws an
            // NSException on corrupt input, which is uncatchable in Swift and kills the process.
            // The index_dense_t format starts with [uint32 vector_count][uint32 bytes_per_vector].
            // Tested against USearch 2.x — bump currentIndexVersion if the library is upgraded.
            // If the claimed vector count meets or exceeds storedNextKey (= max key ever assigned + 1),
            // the file is corrupt — skip the load entirely and force a clean re-index.
            if let fileData = FileManager.default.contents(atPath: indexPath),
               fileData.count >= 4 {
                let claimedCount = fileData.withUnsafeBytes { $0.load(as: UInt32.self) }
                if UInt64(claimedCount) >= storedNextKey {
                    vectorIndex = USearchIndex.make(
                        metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                    )
                    vectorIndex.reserve(64)
                    db.clearAll()
                    return true
                }
            }

            vectorIndex.load(path: indexPath)

            let loadedCount = vectorIndex.count

            // If the loaded index has no active vectors, the HNSW entry-point may still
            // reference a soft-deleted node (USearch does not reset it on remove()).
            // Calling add() on such an index throws an uncatchable NSException. Reset.
            if loadedCount == 0 {
                vectorIndex = USearchIndex.make(
                    metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                )
                vectorIndex.reserve(64)
                db.clearAll()
                return true
            }

            let capacity = max(UInt32(loadedCount) + 16, 64)
            vectorIndex.reserve(capacity)

            // Detect inconsistency: note_chunks has keys beyond what notes.usearch contains.
            // This happens when a previous session was interrupted mid-indexAll().
            // Force a clean re-index by wiping the persisted state.
            let maxChunkKey = db.maxChunkKey() ?? 0
            if maxChunkKey >= storedNextKey {
                vectorIndex = USearchIndex.make(
                    metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                )
                vectorIndex.reserve(64)
                db.clearAll()
                return true
            }

            nextKey = storedNextKey
            for uuid in db.allUUIDs() {
                let keys = db.chunkKeys(for: uuid)
                uuidToKeys[uuid] = keys
                for key in keys { keyToUUID[key] = uuid }
            }

            // Detect the inverse inconsistency: usearch has active vectors but the DB has
            // no chunk mappings. This happens when removeNote() cleared the DB synchronously
            // but the deferred save (scheduleSave) was cancelled by app termination before
            // it could write the updated usearch file to disk.
            if loadedCount > 0, uuidToKeys.isEmpty {
                vectorIndex = USearchIndex.make(
                    metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                )
                vectorIndex.reserve(64)
                db.clearAll()
                return true
            }

            // Apply removes recorded synchronously by removeNote() whose deferred usearch save
            // (scheduleSave) never completed — e.g. the app quit within the 3-second window.
            // Pending keys are NOT cleared here; saveToDisk() clears them after persisting the
            // updated usearch file, making the application idempotent across crashes.
            let pendingKeys = db.pendingRemoveKeys()
            for key in pendingKeys {
                vectorIndex.remove(key: key)
                keyToUUID.removeValue(forKey: key)
            }

            // Verify consistency after applying pending removes.
            // A remaining mismatch indicates genuine corruption — reset and force re-index.
            let totalDBKeys = uuidToKeys.values.reduce(0) { $0 + $1.count }
            if vectorIndex.count != totalDBKeys {
                vectorIndex = USearchIndex.make(
                    metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
                )
                vectorIndex.reserve(64)
                uuidToKeys = [:]
                keyToUUID = [:]
                nextKey = 1
                db.clearAll()
                return true
            }

            return false
        }

        // Fresh start: version mismatch or missing usearch file.
        // clearAll() instead of clearHashes() prevents stale note_chunks / FTS / meta entries
        // from an older schema surviving into the new session, which would cause a false
        // count mismatch on the next cold start and trigger an unnecessary full reset.
        db.clearAll()
        return false
    }

    /// Persist index and mapping to disk.
    func saveToDisk() {
        saveTask?.cancel()
        saveTask = nil
        let storageDir = URL(fileURLWithPath: indexPath).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: storageDir.path) else { return }
        // Mark dirty before writing so a crash mid-save is detected on next launch.
        db.setMeta("index_dirty", 1)
        vectorIndex.save(path: indexPath)
        db.setMeta("index_dirty", 0)
        db.setMeta("index_version", Self.currentIndexVersion)
        db.setMeta("next_key", Int(nextKey))
        db.clearPendingRemoves()
    }

    // MARK: - Indexing

    /// Index or re-index a single note. The body is split into paragraphs; each paragraph
    /// becomes a separate vector. Documents use the "passage: " E5 prefix.
    func indexNote(_ note: Note) async throws {
        try await indexNoteCore(note)
        scheduleSave()
    }

    /// Index a note only if its body or tags have changed since the last indexing.
    /// Used by the per-note queue worker to skip unchanged notes during load and reload.
    func indexNoteIfChanged(_ note: Note) async throws {
        let hashUnchanged = db.md5(for: note.id) == NoteIndexer.contentHash(for: note)
        let filenameUnchanged = db.filenameForID(note.id) == note.filename
        guard !hashUnchanged || !filenameUnchanged else { return }
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
        let chunks = Array((metaChunks + NoteIndexer.paragraphs(cleanBody)).prefix(Self.maxChunksPerNote))

        let needed = max(UInt32(vectorIndex.count) + UInt32(chunks.count), 64)
        vectorIndex.reserve(needed)

        for chunk in chunks {
            let vector = try await embed("passage: \(chunk)")
            // Re-check after await: note may have been deleted while embedding was running.
            guard uuidToKeys[note.id] != nil else { return }
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
        let linkTargets = NoteIndexer.extractWikilinkNames(from: note.body)
            .compactMap { db.resolveFilename($0) }
        db.setLinks(source: note.id, targets: linkTargets)
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
        db.removeLinks(source: id)
        db.removeLinksTo(target: id)
        db.addPendingRemoves(keys: keys)
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

        // Pre-populate note_meta for all notes being indexed so that cross-note
        // wikilink resolution succeeds regardless of processing order.
        for note in toIndex { db.upsertMeta(filename: note.filename, for: note.id) }

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

    private func embed(_ text: String) async throws -> [Float] {
        try await embedder.embed(text)
    }

    // MARK: - Link graph

    func outgoingLinks(from noteID: UUID) async -> [UUID] { db.outgoingLinks(from: noteID) }
    func incomingLinks(to noteID: UUID) async -> [UUID] { db.incomingLinks(to: noteID) }
    func allLinks() async -> [(source: UUID, target: UUID)] { db.allLinks() }

    // MARK: - Private: chunking

    /// Split markdown-stripped body into non-empty paragraphs.
    private nonisolated static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func extractWikilinkNames(from body: String) -> [String] {
        body.matches(of: /\[\[([^\]]+)\]\]/)
            .map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
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
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self.performDeferredSave()
        }
    }

    private func performDeferredSave() async {
        saveToDisk()
    }

    // MARK: - Private: content hash

    // MD5 is used here purely for change-detection, not cryptography.
    private nonisolated static func contentHash(for note: Note) -> String {
        let raw = note.body + note.tags.sorted().joined()
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
