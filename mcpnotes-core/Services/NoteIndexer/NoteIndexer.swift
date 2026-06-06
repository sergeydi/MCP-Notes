import CoreML
import CryptoKit
import Embeddings
import Foundation
import USearch

/// Manages on-device vector indexing and semantic search for notes.
/// Uses multilingual-e5-small (XLM-RoBERTa) downloaded from HuggingFace Hub on first launch.
/// All data lives in Application Support — never synced to iCloud.
public actor NoteIndexer: NoteIndexing {

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

    public init(storageDirectory: URL? = nil) {
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
        vectorIndex.reserve(64)
    }

    // MARK: - NoteIndexing

    /// Returns the number of indexed notes (not chunk vectors).
    public func indexedCount() async -> Int { uuidToKeys.count }

    // MARK: - Lifecycle

    /// Load persisted index and key mapping. Call once on app launch after NoteStore.load().
    /// Returns `true` if the index was corrupted or inconsistent and had to be reset.
    @discardableResult
    public func loadFromDisk() -> Bool {
        // Try current SQLite format first.
        if let storedVersion = db.intMeta("index_version"),
           storedVersion == Self.currentIndexVersion,
           FileManager.default.fileExists(atPath: indexPath) {
            let storedNextKey = UInt64(db.intMeta("next_key") ?? 1)

            // Validate the usearch file header BEFORE loading. USearch's load() throws an
            // NSException on corrupt input, which is uncatchable in Swift and kills the process.
            // The index_dense_t format starts with [uint32 vector_count][uint32 bytes_per_vector].
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
            return false
        }

        // Fresh start — clear hashes so indexAll() re-indexes everything.
        db.clearHashes()
        return false
    }

    /// Persist index and mapping to disk.
    public func saveToDisk() {
        saveTask?.cancel()
        saveTask = nil
        vectorIndex.save(path: indexPath)
        db.setMeta("index_version", Self.currentIndexVersion)
        db.setMeta("next_key", Int(nextKey))
    }

    // MARK: - Indexing

    /// Index or re-index a single note. The body is split into paragraphs; each paragraph
    /// becomes a separate vector. Documents use the "passage: " E5 prefix.
    public func indexNote(_ note: Note) async throws {
        try await indexNoteCore(note)
        scheduleSave()
    }

    /// Index a note only if its body or tags have changed since the last indexing.
    /// Used by the per-note queue worker to skip unchanged notes during load and reload.
    public func indexNoteIfChanged(_ note: Note) async throws {
        let hash = NoteIndexer.contentHash(for: note)
        guard db.md5(for: note.id) != hash else { return }
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
        let linkTargets = NoteIndexer.extractWikilinkNames(from: note.body)
            .compactMap { db.resolveFilename($0) }
        db.setLinks(source: note.id, targets: linkTargets)
    }

    /// Remove a note and all its chunk vectors from the index.
    public func removeNote(id: UUID) {
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
        scheduleSave()
    }

    /// Incrementally sync the index: remove deleted notes, skip unchanged notes,
    /// re-index only new or modified ones.
    public func indexAll(_ notes: [Note]) async throws {
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
    public func clearHashStore() {
        db.clearHashes()
    }

    /// Wipe the entire index. Used before a manual full re-index from Settings.
    public func resetAndClearIndex() {
        uuidToKeys = [:]
        keyToUUID = [:]
        nextKey = 1
        vectorIndex = USearchIndex.make(metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32)
        db.clearAll()
    }

    // MARK: - Search

    /// Returns notes ranked by BM25 keyword relevance (rank 1 = best match).
    public func searchBM25Ranked(query: String, limit: Int = 10) -> [(id: UUID, rank: Int)] {
        db.searchFTS(query: query, limit: limit)
            .enumerated().map { (id: $0.element.0, rank: $0.offset + 1) }
    }

    /// Returns note UUIDs ranked by semantic similarity, closest first.
    public func search(query: String, limit: Int = 10) async throws -> [UUID] {
        try await searchRanked(query: query, limit: limit).map(\.id)
    }

    /// Returns note UUIDs with their best-chunk cosine similarity scores (0–1), highest first.
    public func searchRanked(query: String, limit: Int = 10) async throws -> [(id: UUID, score: Float)] {
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

    // MARK: - Link graph

    public func outgoingLinks(from noteID: UUID) async -> [UUID] { db.outgoingLinks(from: noteID) }
    public func incomingLinks(to noteID: UUID) async -> [UUID] { db.incomingLinks(to: noteID) }
    public func allLinks() async -> [(source: UUID, target: UUID)] { db.allLinks() }

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

    public nonisolated static func stripMarkdown(_ text: String) -> String {
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
