import Foundation

struct Note: Sendable {
    var id: UUID
    var filename: String
    var tags: [String]
    var isBookmarked: Bool
    var body: String
    var fileURL: URL
}
