import Foundation

struct Note: Sendable {
    var id: UUID
    var filename: String
    var tags: [String]
    var body: String
    var fileURL: URL
}
