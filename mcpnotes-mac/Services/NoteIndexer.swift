import CoreML
import Embeddings
import Foundation
import USearch

protocol NoteIndexing {
    func loadFromDisk() async
    func indexedCount() async -> Int
    func indexAll(_ notes: [Note]) async throws
    func indexNote(_ note: Note) async throws
    func removeNote(id: UUID) async
    func search(query: String, limit: Int) async throws -> [UUID]
    func searchRanked(query: String, limit: Int) async throws -> [(id: UUID, score: Float)]
}

/// Manages on-device vector indexing and semantic search for notes.
/// Uses multilingual-e5-small (XLM-RoBERTa) downloaded from HuggingFace Hub on first launch.
/// All data lives in Application Support — never synced to iCloud.
actor NoteIndexer: NoteIndexing {

    // MARK: - Constants

    private static let modelID = "intfloat/multilingual-e5-small"
    /// multilingual-e5-small hidden size.
    private static let dimensions: UInt32 = 384
    /// Bump when the chunking strategy or index format changes to force a full re-index.
    private static let currentIndexVersion = 6

    // MARK: - State

    private var modelBundle: XLMRoberta.ModelBundle?
    private var modelLoadTask: Task<XLMRoberta.ModelBundle, Error>?
    private let vectorIndex: USearchIndex
    /// Maps each note UUID to the keys of all its indexed chunks.
    private var uuidToKeys: [UUID: [UInt64]] = [:]
    private var keyToUUID: [UInt64: UUID] = [:]
    private var nextKey: UInt64 = 1
    private var saveTask: Task<Void, Never>?

    // MARK: - Paths

    private let indexPath: String
    private let mappingURL: URL

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
        mappingURL = dir.appendingPathComponent("notes-keys.json")
        vectorIndex = USearchIndex.make(metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32)
    }

    // MARK: - NoteIndexing

    /// Returns the number of indexed notes (not chunk vectors).
    func indexedCount() async -> Int { uuidToKeys.count }

    // MARK: - Lifecycle

    /// Load persisted index and key mapping. Call once on app launch after NoteStore.load().
    func loadFromDisk() {
        // Check version before loading vectors: if stale, skip loading the binary index
        // so we start with an empty USearch state and avoid capacity/crash issues.
        let mappingIsCurrentVersion: Bool = {
            guard let data = try? Data(contentsOf: mappingURL),
                  let decoded = try? JSONDecoder().decode(KeyMapping.self, from: data)
            else { return false }
            return decoded.indexVersion == Self.currentIndexVersion
        }()

        guard mappingIsCurrentVersion, FileManager.default.fileExists(atPath: indexPath) else {
            // Fresh index — do NOT reserve here; indexAll will do the single reserve
            // with the correct total capacity before any add() calls.
            return
        }

        vectorIndex.load(path: indexPath)
        // Reserve restores the runtime thread-slot structures that are not persisted to disk.
        // Without this, vectorIndex.add() crashes (USearch thread_lock_ finds 0 slots).
        let capacity = max(UInt32(vectorIndex.count) + 16, 64)
        vectorIndex.reserve(capacity)
        loadMapping()
    }

    /// Persist index and mapping to disk.
    func saveToDisk() {
        saveTask?.cancel()
        saveTask = nil
        vectorIndex.save(path: indexPath)
        saveMapping()
    }

    // MARK: - Indexing

    /// Index or re-index a single note. The body is split into paragraphs; each paragraph
    /// becomes a separate vector. Documents use the "passage: " E5 prefix.
    func indexNote(_ note: Note) async throws {
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

        scheduleSave()
    }

    /// Remove a note and all its chunk vectors from the index.
    func removeNote(id: UUID) {
        guard let keys = uuidToKeys[id] else { return }
        for key in keys {
            vectorIndex.remove(key: key)
            keyToUUID.removeValue(forKey: key)
        }
        uuidToKeys.removeValue(forKey: id)
        scheduleSave()
    }

    /// Bulk-index notes and save to disk. Re-indexes any note already in the index.
    func indexAll(_ notes: [Note]) async throws {
        // Single reserve before any add() calls. For a fresh index this is the only reserve;
        // for a loaded index loadFromDisk already reserved. Use 10× headroom to be safe.
        let needed = max(UInt32(vectorIndex.count) + UInt32(notes.count * 10), 64)
        vectorIndex.reserve(needed)
        for note in notes {
            try await indexNote(note)
        }
        saveToDisk()
    }

    // MARK: - Search

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
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            saveToDisk()
        }
    }

    // MARK: - Private: key mapping

    private func loadMapping() {
        guard
            let data = try? Data(contentsOf: mappingURL),
            let decoded = try? JSONDecoder().decode(KeyMapping.self, from: data)
        else { return }
        guard decoded.indexVersion == Self.currentIndexVersion else { return }
        nextKey = decoded.nextKey
        for entry in decoded.entries {
            let keys = entry.allKeys
            uuidToKeys[entry.uuid] = keys
            for key in keys {
                keyToUUID[key] = entry.uuid
            }
        }
    }

    private func saveMapping() {
        let entries = uuidToKeys.map { KeyMapping.Entry(uuid: $0.key, keys: $0.value) }
        let mapping = KeyMapping(indexVersion: Self.currentIndexVersion, nextKey: nextKey, entries: entries)
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        try? data.write(to: mappingURL, options: .atomic)
    }

    private struct KeyMapping: Codable {
        let indexVersion: Int?
        let nextKey: UInt64
        let entries: [Entry]

        struct Entry: Codable {
            let uuid: UUID
            /// New format: multiple chunk keys per note.
            let keys: [UInt64]?
            /// Legacy format: single key. Present only when reading old index files.
            let key: UInt64?

            init(uuid: UUID, keys: [UInt64]) {
                self.uuid = uuid
                self.keys = keys
                self.key = nil
            }

            var allKeys: [UInt64] {
                if let keys = keys, !keys.isEmpty { return keys }
                if let key = key { return [key] }
                return []
            }
        }
    }
}
