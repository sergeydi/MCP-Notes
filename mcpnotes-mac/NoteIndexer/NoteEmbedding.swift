import Foundation

protocol NoteEmbedding: Sendable {
    func embed(_ text: String) async throws -> [Float]
}
