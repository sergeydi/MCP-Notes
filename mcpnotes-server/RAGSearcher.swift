import CoreML
import Embeddings
import Foundation
import SQLite3
import USearch

struct HybridSearchResult: Sendable {
    let uuid: UUID
    let vectorScore: Float
    let vectorRank: Int
    let bm25Rank: Int?      // nil = not in BM25 top-N
    let hybridScore: Double
}

protocol RAGSearching: Actor {
    var isReady: Bool { get }
    func searchRanked(query: String, limit: Int) async throws -> [(uuid: UUID, score: Float)]
    func searchRankedHybrid(query: String, limit: Int) async throws -> [HybridSearchResult]
    func allTags() async -> [(tag: String, count: Int)]
    func notes(forTag tag: String) async -> [(uuid: UUID, filename: String)]
    func outgoingLinks(from noteID: UUID) async -> [(uuid: UUID, filename: String)]
    func incomingLinks(to noteID: UUID) async -> [(uuid: UUID, filename: String)]
}

/// Loads the vector index built by the main app and runs semantic search queries.
/// The index lives in the sandboxed app container — this actor finds it automatically.
actor RAGSearcher: RAGSearching {

    private static let modelID = "intfloat/multilingual-e5-small"
    private static let dimensions: UInt32 = 384
    private static let currentIndexVersion = 8

    nonisolated(unsafe) private var vectorIndex: USearchIndex = .make(metric: .cos, dimensions: 384, connectivity: 16, quantization: .F32)
    nonisolated(unsafe) private var keyToUUID: [UInt64: UUID] = [:]
    private var modelBundle: XLMRoberta.ModelBundle?
    private let indexPath: String
    private let dbURL: URL
    nonisolated(unsafe) private var indexModDate: Date?
    /// When set, replaces real model inference. Lets tests pass a fixed vector without loading CoreML.
    private let customEmbedder: ((String) async throws -> [Float])?

    init() {
        let dir = Self.ragDirectory
        indexPath = dir.appendingPathComponent("notes.usearch").path
        dbURL = dir.appendingPathComponent("notes-index.db")
        customEmbedder = nil
        loadFromSQLite(dbURL: dbURL, indexPath: indexPath)
        indexModDate = (try? FileManager.default.attributesOfItem(atPath: indexPath))?[.modificationDate] as? Date
    }

    /// Loads the index from a custom directory. Used in tests to avoid touching the app container.
    init(storageDirectory: URL, embedder: ((String) async throws -> [Float])? = nil) {
        indexPath = storageDirectory.appendingPathComponent("notes.usearch").path
        dbURL = storageDirectory.appendingPathComponent("notes-index.db")
        customEmbedder = embedder
        loadFromSQLite(dbURL: dbURL, indexPath: indexPath)
        indexModDate = (try? FileManager.default.attributesOfItem(atPath: indexPath))?[.modificationDate] as? Date
    }

    var isReady: Bool {
        reloadIfNeeded()
        return vectorIndex.count > 0
    }

    func searchRanked(query: String, limit: Int) async throws -> [(uuid: UUID, score: Float)] {
        guard vectorIndex.count > 0 else { return [] }
        let queryVector = try await embed("query: \(query)")
        let (keys, distances) = vectorIndex.search(vector: queryVector, count: limit * 5)

        var best: [UUID: Float] = [:]
        for (key, distance) in zip(keys, distances) {
            guard let uuid = keyToUUID[key] else { continue }
            let score = 1 - distance
            if (best[uuid] ?? 0) < score { best[uuid] = score }
        }

        return best.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (uuid: $0.key, score: $0.value) }
    }

    func searchRankedHybrid(query: String, limit: Int) async throws -> [HybridSearchResult] {
        guard vectorIndex.count > 0 else { return [] }
        let vectorResults = try await searchRanked(query: query, limit: limit)
        let vectorMap = Dictionary(uniqueKeysWithValues: vectorResults.enumerated()
            .map { i, h in (h.uuid, (score: h.score, rank: i + 1)) })
        let bm25Map = Dictionary(uniqueKeysWithValues:
            bm25Ranked(query: query, limit: limit * 5).map { ($0.uuid, $0.rank) })
        let k = 60.0
        let penalty = limit * 10
        return vectorMap.keys.compactMap { uuid -> HybridSearchResult? in
            guard let v = vectorMap[uuid] else { return nil }
            let b = bm25Map[uuid]
            return HybridSearchResult(
                uuid: uuid,
                vectorScore: v.score,
                vectorRank: v.rank,
                bm25Rank: b,
                hybridScore: 1.0 / (k + Double(v.rank)) + 1.0 / (k + Double(b ?? penalty))
            )
        }
        .sorted { $0.hybridScore > $1.hybridScore }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: - Private: disk loading

    private func reloadIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: indexPath)
        let current = attrs?[.modificationDate] as? Date
        guard current != indexModDate else { return }
        indexModDate = current
        keyToUUID = [:]
        vectorIndex = USearchIndex.make(metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32)
        loadFromSQLite(dbURL: dbURL, indexPath: indexPath)
    }

    @discardableResult
    private nonisolated func loadFromSQLite(dbURL: URL, indexPath: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }

        // Verify index version
        var vStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'index_version'", -1, &vStmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(vStmt) }
        guard sqlite3_step(vStmt) == SQLITE_ROW,
              Int(sqlite3_column_int64(vStmt, 0)) == Self.currentIndexVersion,
              FileManager.default.fileExists(atPath: indexPath) else { return false }

        // Load vector index from disk
        vectorIndex.load(path: indexPath)
        let capacity = max(UInt32(vectorIndex.count) + 16, 64)
        vectorIndex.reserve(capacity)

        // Populate chunk-key → UUID mapping
        var cStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT uuid, chunk_key FROM note_chunks", -1, &cStmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(cStmt) }
        while sqlite3_step(cStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(cStmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr)) {
                let key = UInt64(bitPattern: sqlite3_column_int64(cStmt, 1))
                keyToUUID[key] = uuid
            }
        }
        return true
    }

    private static var ragDirectory: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.mcp-notes") {
            return group.appendingPathComponent("mcpnotes/rag")
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("mcpnotes/rag")
    }

    private func bm25Ranked(query: String, limit: Int) -> [(uuid: UUID, rank: Int)] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT uuid, bm25(notes_fts) FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts) LIMIT ?",
            -1, &stmt, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sanitized, -1, transient)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var results: [(uuid: UUID, rank: Int)] = []
        var rank = 1
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: cStr)) else { continue }
            results.append((uuid: uuid, rank: rank))
            rank += 1
        }
        return results
    }

    func allTags() async -> [(tag: String, count: Int)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tag, COUNT(*) FROM note_tags GROUP BY tag ORDER BY tag", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [(tag: String, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            results.append((tag: String(cString: cStr), count: Int(sqlite3_column_int64(stmt, 1))))
        }
        return results
    }

    func notes(forTag tag: String) async -> [(uuid: UUID, filename: String)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT nt.uuid, nm.filename FROM note_tags nt JOIN note_meta nm ON nt.uuid = nm.uuid WHERE nt.tag = ? ORDER BY nm.filename",
            -1, &stmt, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, tag, -1, transient)
        var results: [(uuid: UUID, filename: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuidCStr = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: uuidCStr)),
                  let filenameCStr = sqlite3_column_text(stmt, 1) else { continue }
            results.append((uuid: uuid, filename: String(cString: filenameCStr)))
        }
        return results
    }

    func outgoingLinks(from noteID: UUID) async -> [(uuid: UUID, filename: String)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT nl.target_uid, nm.filename
            FROM note_links nl JOIN note_meta nm ON nl.target_uid = nm.uuid
            WHERE nl.source_uid = ? ORDER BY nm.filename
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, noteID.uuidString, -1, transient)
        var results: [(uuid: UUID, filename: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuidCStr = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: uuidCStr)),
                  let filenameCStr = sqlite3_column_text(stmt, 1) else { continue }
            results.append((uuid: uuid, filename: String(cString: filenameCStr)))
        }
        return results
    }

    func incomingLinks(to noteID: UUID) async -> [(uuid: UUID, filename: String)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT nl.source_uid, nm.filename
            FROM note_links nl JOIN note_meta nm ON nl.source_uid = nm.uuid
            WHERE nl.target_uid = ? ORDER BY nm.filename
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, noteID.uuidString, -1, transient)
        var results: [(uuid: UUID, filename: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuidCStr = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: uuidCStr)),
                  let filenameCStr = sqlite3_column_text(stmt, 1) else { continue }
            results.append((uuid: uuid, filename: String(cString: filenameCStr)))
        }
        return results
    }

    private func sanitizeFTSQuery(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !"\"*()-^:\\".contains(Character($0)) }
        return String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Private: embedding

    private func loadedModel() async throws -> XLMRoberta.ModelBundle {
        if let bundle = modelBundle { return bundle }
        let bundle = try await XLMRoberta.loadModelBundle(from: Self.modelID)
        modelBundle = bundle
        return bundle
    }

    private func embed(_ text: String) async throws -> [Float] {
        if let custom = customEmbedder { return try await custom(text) }
        let bundle = try await loadedModel()
        let tokens = try bundle.tokenizer.tokenizeText(text, maxLength: 512)
        let seqLen = tokens.count
        let inputIds = MLTensor(shape: [1, seqLen], scalars: tokens)
        let attentionMask = MLTensor(ones: [1, seqLen], scalarType: Float32.self)
        let output = bundle.model(inputIds: inputIds, attentionMask: attentionMask)
        let pooled = output.sequenceOutput.mean(alongAxes: 1, keepRank: false)
        var vector = await pooled.cast(to: Float.self).shapedArray(of: Float.self).scalars
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { vector = vector.map { $0 / norm } }
        return vector
    }

}
