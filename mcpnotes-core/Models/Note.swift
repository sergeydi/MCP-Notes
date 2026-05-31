import Foundation

/// A note stored as a Markdown file with YAML frontmatter.
public struct Note: Identifiable, Hashable, Sendable {
    /// Unique identifier stored in the frontmatter `uid` field.
    public var id: UUID
    /// Display name — the file name without the `.md` extension.
    public var filename: String
    /// Tags associated with the note, stored in frontmatter.
    public var tags: [String]
    /// Markdown body content after the frontmatter block.
    public var body: String
    /// URL of the note file on disk.
    public var fileURL: URL
    /// Whether this note is bookmarked (persisted as `bookmarked: true` in frontmatter).
    public var isBookmarked: Bool
    /// Last modification date of the note file on disk.
    public var modifiedAt: Date
    /// Creation date of the note file on disk.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        filename: String,
        tags: [String] = [],
        body: String = "",
        fileURL: URL,
        isBookmarked: Bool = false,
        modifiedAt: Date = .now,
        createdAt: Date = .now
    ) {
        self.id = id
        self.filename = filename
        self.tags = tags
        self.body = body
        self.fileURL = fileURL
        self.isBookmarked = isBookmarked
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}
