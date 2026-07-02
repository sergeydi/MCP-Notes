import CoreML
import Embeddings
import Foundation

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EmbeddingXPCProtocol.self)
        newConnection.exportedObject = EmbeddingServiceImpl()
        newConnection.invalidationHandler = { exit(0) }
        newConnection.resume()
        return true
    }
}

final class EmbeddingServiceImpl: NSObject, EmbeddingXPCProtocol {
    private let state = ModelState()

    func embed(text: String, reply: @escaping (Data?) -> Void) {
        Task {
            let data = await state.embed(text: text)
            reply(data)
        }
    }
}

actor ModelState {
    private static let modelID = "intfloat/multilingual-e5-small"
    private var bundle: XLMRoberta.ModelBundle?
    private var loadTask: Task<XLMRoberta.ModelBundle, Error>?

    func embed(text: String) async -> Data? {
        do {
            let b = try await loadedBundle()
            let tokens = try b.tokenizer.tokenizeText(text, maxLength: 512)
            let seqLen = tokens.count
            let inputIds = MLTensor(shape: [1, seqLen], scalars: tokens)
            let attentionMask = MLTensor(ones: [1, seqLen], scalarType: Float32.self)
            let output = b.model(inputIds: inputIds, attentionMask: attentionMask)
            let pooled = output.sequenceOutput.mean(alongAxes: 1, keepRank: false)
            var vector = await pooled.cast(to: Float.self).shapedArray(of: Float.self).scalars
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { vector = vector.map { $0 / norm } }
            return vector.withUnsafeBytes { Data($0) }
        } catch {
            return nil
        }
    }

    private func loadedBundle() async throws -> XLMRoberta.ModelBundle {
        if let b = bundle { return b }
        if let t = loadTask { return try await t.value }
        let t = Task { try await XLMRoberta.loadModelBundle(from: Self.modelID) }
        loadTask = t
        do {
            let b = try await t.value
            bundle = b
            loadTask = nil
            return b
        } catch {
            loadTask = nil
            throw error
        }
    }
}
