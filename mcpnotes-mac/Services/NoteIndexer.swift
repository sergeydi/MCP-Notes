import CoreML
import Embeddings
import Foundation
import USearch

/// Manages on-device vector indexing and semantic search for notes.
/// Uses multilingual-e5-small (XLM-RoBERTa) downloaded from HuggingFace Hub on first launch.
/// All data lives in Application Support — never synced to iCloud.
actor NoteIndexer {

    // MARK: - Constants

    private static let modelID = "intfloat/multilingual-e5-small"
    /// multilingual-e5-small hidden size.
    private static let dimensions: UInt32 = 384

    // MARK: - State

    private var modelBundle: XLMRoberta.ModelBundle?
    private var modelLoadTask: Task<XLMRoberta.ModelBundle, Error>?
    private let vectorIndex: USearchIndex
    private var uuidToKey: [UUID: UInt64] = [:]
    private var keyToUUID: [UInt64: UUID] = [:]
    private var nextKey: UInt64 = 1
    private var filenameToUUID: [String: UUID] = [:]
    private var noteLinks: [UUID: [UUID]] = [:]
    private var vectorCache: [UUID: [Float]] = [:]
    private var saveTask: Task<Void, Never>?

    // MARK: - Paths

    private let indexPath: String
    private let mappingURL: URL

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("mcpnotes/rag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexPath = dir.appendingPathComponent("notes.usearch").path
        mappingURL = dir.appendingPathComponent("notes-keys.json")
        vectorIndex = USearchIndex.make(metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32)
    }

    // MARK: - Lifecycle

    /// Load persisted index and key mapping. Call once on app launch after NoteStore.load().
    func loadFromDisk() {
        if FileManager.default.fileExists(atPath: indexPath) {
            vectorIndex.load(path: indexPath)
        }
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

    /// Index or re-index a single note. Documents use the "passage: " E5 prefix.
    func indexNote(_ note: Note) async throws {
        filenameToUUID[note.filename.lowercased()] = note.id
        let tags = note.tags.isEmpty ? "" : "\(note.tags.joined(separator: " "))\n"
        let links = wikilinks(in: note.body)
        let linksText = links.isEmpty ? "" : "\(links.joined(separator: " "))\n"
        let cleanBody = NoteIndexer.stripMarkdown(note.body)
        let text = "passage: \(note.filename)\n\(tags)\(linksText)\(cleanBody)"
        let vector = try await embed(text)
        let key = ensureKey(for: note.id)
        if vectorIndex.contains(key: key) {
            vectorIndex.remove(key: key)
        }
        vectorIndex.add(key: key, vector: vector)
        vectorCache[note.id] = vector
        noteLinks[note.id] = links.compactMap { filenameToUUID[$0.lowercased()] }
        scheduleSave()
    }

    /// Remove a note from the index.
    func removeNote(id: UUID) {
        guard let key = uuidToKey[id] else { return }
        vectorIndex.remove(key: key)
        uuidToKey.removeValue(forKey: id)
        keyToUUID.removeValue(forKey: key)
        noteLinks.removeValue(forKey: id)
        vectorCache.removeValue(forKey: id)
        filenameToUUID = filenameToUUID.filter { $0.value != id }
        scheduleSave()
    }

    /// Bulk-index notes and save to disk. Re-indexes any note already in the index.
    func indexAll(_ notes: [Note]) async throws {
        // Pre-populate filename map so forward wikilink references resolve correctly.
        for note in notes {
            filenameToUUID[note.filename.lowercased()] = note.id
        }
        vectorIndex.reserve(UInt32(notes.count))
        for note in notes {
            try await indexNote(note)
        }
        saveToDisk()
    }

    // MARK: - Search

    /// Returns note UUIDs ranked by semantic similarity, closest first.
    /// When `expandLinks` is true (default), notes linked from primary results are included
    /// and the full result set is re-ranked by cosine similarity so graph-expanded notes
    /// appear in the correct position relative to primary hits.
    func search(query: String, limit: Int = 10, expandLinks: Bool = true) async throws -> [UUID] {
        guard vectorIndex.count > 0 else { return [] }
        let queryVector = try await embed("query: \(query)")
        let (keys, distances) = vectorIndex.search(vector: queryVector, count: limit)

        // USearch cosine metric returns distance = 1 − similarity; convert back.
        var scores: [UUID: Float] = [:]
        for (key, distance) in zip(keys, distances) {
            guard let uuid = keyToUUID[key] else { continue }
            scores[uuid] = 1 - distance
        }

        guard expandLinks else {
            return scores.sorted { $0.value > $1.value }.map(\.key)
        }

        // Score linked notes via dot product (valid because all vectors are L2-normalised).
        for uuid in Array(scores.keys) {
            guard let linked = noteLinks[uuid] else { continue }
            for linkedID in linked where scores[linkedID] == nil {
                guard let vec = vectorCache[linkedID] else { continue }
                scores[linkedID] = zip(queryVector, vec).reduce(0) { $0 + $1.0 * $1.1 }
            }
        }

        return scores.sorted { $0.value > $1.value }.map(\.key)
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

    // MARK: - Private: wikilinks

    private static let wikilinkRegex = /\[\[([^\[\]]+)\]\]/

    private func wikilinks(in text: String) -> [String] {
        text.matches(of: Self.wikilinkRegex).map { String($0.output.1) }
    }

    // MARK: - Private: markdown stripping

    static func stripMarkdown(_ text: String) -> String {
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

    private func ensureKey(for id: UUID) -> UInt64 {
        if let key = uuidToKey[id] { return key }
        let key = nextKey
        nextKey += 1
        uuidToKey[id] = key
        keyToUUID[key] = id
        return key
    }

    private func loadMapping() {
        guard
            let data = try? Data(contentsOf: mappingURL),
            let decoded = try? JSONDecoder().decode(KeyMapping.self, from: data)
        else { return }
        nextKey = decoded.nextKey
        for entry in decoded.entries {
            uuidToKey[entry.uuid] = entry.key
            keyToUUID[entry.key] = entry.uuid
        }
        for entry in decoded.links ?? [] {
            noteLinks[entry.sourceID] = entry.targetIDs
        }
        for entry in decoded.filenameMap ?? [] {
            filenameToUUID[entry.filename] = entry.uuid
        }
        for entry in decoded.vectors ?? [] {
            vectorCache[entry.uuid] = entry.vector
        }
    }

    private func saveMapping() {
        let entries = uuidToKey.map { KeyMapping.Entry(uuid: $0.key, key: $0.value) }
        let links = noteLinks.map { KeyMapping.LinkEntry(sourceID: $0.key, targetIDs: $0.value) }
        let filenameEntries = filenameToUUID.map { KeyMapping.FilenameEntry(filename: $0.key, uuid: $0.value) }
        let vectorEntries = vectorCache.map { KeyMapping.VectorEntry(uuid: $0.key, vector: $0.value) }
        let mapping = KeyMapping(nextKey: nextKey, entries: entries, links: links, filenameMap: filenameEntries, vectors: vectorEntries)
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        try? data.write(to: mappingURL, options: .atomic)
    }

    private struct KeyMapping: Codable {
        let nextKey: UInt64
        let entries: [Entry]
        let links: [LinkEntry]?
        let filenameMap: [FilenameEntry]?
        let vectors: [VectorEntry]?

        struct Entry: Codable {
            let uuid: UUID
            let key: UInt64
        }

        struct LinkEntry: Codable {
            let sourceID: UUID
            let targetIDs: [UUID]
        }

        struct FilenameEntry: Codable {
            let filename: String
            let uuid: UUID
        }

        struct VectorEntry: Codable {
            let uuid: UUID
            let data: Data

            init(uuid: UUID, vector: [Float]) {
                self.uuid = uuid
                self.data = vector.withUnsafeBytes { Data($0) }
            }

            var vector: [Float] {
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
    }
}
