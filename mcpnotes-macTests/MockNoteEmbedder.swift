import Foundation
@testable import mcpnotes_mac

/// Deterministic embedder for unit tests. Returns a 384-dim unit vector
/// derived from the text hash — fast, no ML, no XPC required.
/// Not semantically meaningful; suitable for tests that only check
/// index structure, BM25 results, or note presence/absence.
struct MockNoteEmbedder: NoteEmbedding {
    func embed(_ text: String) async throws -> [Float] {
        var seed = UInt64(bitPattern: Int64(text.hashValue))
        var vector = (0..<384).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 33) / Float(UInt32.max) * 2 - 1
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { vector = vector.map { $0 / norm } }
        return vector
    }
}
