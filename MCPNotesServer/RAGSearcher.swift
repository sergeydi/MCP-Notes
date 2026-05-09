import CoreML
import Embeddings
import Foundation
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

    private let vectorIndex: USearchIndex
    private var keyToUUID: [UInt64: UUID] = [:]
    private var modelBundle: XLMRoberta.ModelBundle?

    init() {
        vectorIndex = USearchIndex.make(
            metric: .cos, dimensions: Self.dimensions, connectivity: 16, quantization: .F32
        )
        loadFromDisk()
    }

    var isReady: Bool { vectorIndex.count > 0 }

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

    private func loadFromDisk() {
        let dir = Self.ragDirectory
        let indexPath = dir.appendingPathComponent("notes.usearch").path
        let mappingURL = dir.appendingPathComponent("notes-keys.json")

        guard
            let data = try? Data(contentsOf: mappingURL),
            let mapping = try? JSONDecoder().decode(KeyMapping.self, from: data),
            mapping.indexVersion == Self.currentIndexVersion,
            FileManager.default.fileExists(atPath: indexPath)
        else { return }

        vectorIndex.load(path: indexPath)
        let capacity = max(UInt32(vectorIndex.count) + 16, 64)
        vectorIndex.reserve(capacity)

        for entry in mapping.entries {
            for key in entry.allKeys {
                keyToUUID[key] = entry.uuid
            }
        }
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

    // MARK: - Key mapping

    private struct KeyMapping: Codable {
        let indexVersion: Int?
        let nextKey: UInt64
        let entries: [Entry]

        struct Entry: Codable {
            let uuid: UUID
            let keys: [UInt64]?
            let key: UInt64?

            var allKeys: [UInt64] {
                if let keys, !keys.isEmpty { return keys }
                if let key { return [key] }
                return []
            }
        }
    }
}
