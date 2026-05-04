import Foundation

/// A note stored as a Markdown file with YAML frontmatter.
struct Note: Identifiable, Hashable, Sendable {
    /// Unique identifier stored in the frontmatter `uid` field.
    var id: UUID
    /// Display name — the file name without the `.md` extension.
    var filename: String
    /// Tags associated with the note, stored in frontmatter.
    var tags: [String]
    /// Markdown body content after the frontmatter block.
    var body: String
    /// URL of the note file on disk.
    var fileURL: URL
    /// Whether this note is bookmarked (persisted in iCloud Key-Value Store).
    var isBookmarked: Bool

    init(
        id: UUID = UUID(),
        filename: String,
        tags: [String] = [],
        body: String = "",
        fileURL: URL,
        isBookmarked: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.tags = tags
        self.body = body
        self.fileURL = fileURL
        self.isBookmarked = isBookmarked
    }
}
