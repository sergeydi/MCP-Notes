import Foundation

/// Manages the NSXPCConnection to mcpnotes-embeddings service.
/// Closes the connection after 60 s of idle so CoreML/Metal memory is released by the OS.
actor XPCNoteEmbedder: NoteEmbedding {

    private var xpcConnection: NSXPCConnection?
    private var connectionIdleTask: Task<Void, Never>?

    func embed(_ text: String) async throws -> [Float] {
        let conn = activeXPCConnection()
        connectionIdleTask?.cancel()
        connectionIdleTask = nil
        defer { scheduleConnectionClose() }
        return try await withCheckedThrowingContinuation { cont in
            let rawProxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: error)
            }
            guard let proxy = rawProxy as? any EmbeddingXPCProtocol else {
                cont.resume(throwing: EmbeddingError.xpcFailed)
                return
            }
            proxy.embed(text: text) { data in
                guard let data else {
                    cont.resume(throwing: EmbeddingError.xpcFailed)
                    return
                }
                let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                cont.resume(returning: floats)
            }
        }
    }

    private func activeXPCConnection() -> NSXPCConnection {
        if let conn = xpcConnection { return conn }
        let conn = NSXPCConnection(serviceName: "mcpnotes-embeddings")
        conn.remoteObjectInterface = NSXPCInterface(with: EmbeddingXPCProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { [weak self] in await self?.handleXPCInvalidated() }
        }
        conn.resume()
        xpcConnection = conn
        return conn
    }

    private func handleXPCInvalidated() {
        xpcConnection = nil
        connectionIdleTask?.cancel()
        connectionIdleTask = nil
    }

    private func scheduleConnectionClose() {
        connectionIdleTask?.cancel()
        connectionIdleTask = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            xpcConnection?.invalidate()
            xpcConnection = nil
        }
    }
}
