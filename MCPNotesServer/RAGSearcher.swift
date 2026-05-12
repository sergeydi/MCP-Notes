import CoreML
import Embeddings
import Foundation
import SQLite3
import USearch

protocol RAGSearching: Actor {
    var isReady: Bool { get }
    func searchRanked(query: String, limit: Int) async throws -> [(uuid: UUID, score: Float)]
}

/// Loads the vector index built by the main app and runs semantic search queries.
/// The index lives in the sandboxed app container — this actor finds it automatically.
actor RAGSearcher: RAGSearching {

    private static let modelID = "intfloat/multilingual-e5-small"
    private static let dimensions: UInt32 = 384
    private static let currentIndexVersion = 6

    private var vectorIndex: USearchIndex
    private var keyToUUID: [UInt64: UUID] = [:]
    private var modelBundle: XLMRoberta.ModelBundle?
    private let indexPath: String
    private let dbURL: URL
    private var indexModDate: Date?

    init() {
        let dir = Self.ragDirectory
        indexPath = dir.appendingPathComponent("notes.usearch").path
        dbURL = dir.appendingPathComponent("notes-index.db")
        vectorIndex = USearchIndex.make(
            metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
        )
        loadFromSQLite(dbURL: dbURL, indexPath: indexPath)
        indexModDate = (try? FileManager.default.attributesOfItem(atPath: indexPath))?[.modificationDate] as? Date
    }

    /// Loads the index from a custom directory. Used in tests to avoid touching the app container.
    init(storageDirectory: URL) {
        indexPath = storageDirectory.appendingPathComponent("notes.usearch").path
        dbURL = storageDirectory.appendingPathComponent("notes-index.db")
        vectorIndex = USearchIndex.make(
            metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
        )
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
    private func loadFromSQLite(dbURL: URL, indexPath: String) -> Bool {
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
        let sandboxPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/mcp-notes/Data/Library/Application Support/mcpnotes/rag"
            )
        if FileManager.default.fileExists(atPath: sandboxPath.path) {
            return sandboxPath
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("mcpnotes/rag")
    }

    // MARK: - Private: embedding

    private func loadedModel() async throws -> XLMRoberta.ModelBundle {
        if let bundle = modelBundle { return bundle }
        let bundle = try await XLMRoberta.loadModelBundle(from: Self.modelID)
        modelBundle = bundle
        return bundle
    }

    private func embed(_ text: String) async throws -> [Float] {
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
