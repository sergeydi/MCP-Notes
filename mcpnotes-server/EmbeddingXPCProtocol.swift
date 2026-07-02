import Foundation

@objc protocol EmbeddingXPCProtocol {
    func embed(text: String, reply: @escaping (Data?) -> Void)
}

enum EmbeddingError: Error {
    case xpcFailed
}
