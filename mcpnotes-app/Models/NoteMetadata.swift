import Foundation

/// Lightweight, always-in-memory representation of a note — everything except `body`.
///
/// `NoteStore.notes` holds these for every note at all times; the full `Note` (with body) is
/// loaded from disk on demand (see `NoteStore.loadFullNote(_:)`) and is expected to be resident
/// for at most one note at a time (the one open in the editor, or transiently while a single
/// note is being renamed/indexed).
public struct NoteMetadata: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var filename: String
    public var tags: [String]
    public var fileURL: URL
    public var isBookmarked: Bool
    public var modifiedAt: Date
    public var createdAt: Date
    /// Stripped-markdown snippet of the first ~400 raw characters of body, computed once when
    /// the note is read. Powers the sidebar row preview without holding the full body.
    public var preview: String

    public init(
        id: UUID,
        filename: String,
        tags: [String],
        fileURL: URL,
        isBookmarked: Bool,
        modifiedAt: Date,
        createdAt: Date,
        preview: String
    ) {
        self.id = id
        self.filename = filename
        self.tags = tags
        self.fileURL = fileURL
        self.isBookmarked = isBookmarked
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.preview = preview
    }
}

extension NoteMetadata {
    /// Derives metadata from an already-loaded full `Note` — used right after create/update/
    /// rename so callers never need to re-read the file just to refresh the in-memory metadata.
    public init(_ note: Note, previewLength: Int = 400) {
        self.init(
            id: note.id,
            filename: note.filename,
            tags: note.tags,
            fileURL: note.fileURL,
            isBookmarked: note.isBookmarked,
            modifiedAt: note.modifiedAt,
            createdAt: note.createdAt,
            preview: Self.makePreview(from: note.body, maxLength: previewLength)
        )
    }

    public static func makePreview(from body: String, maxLength: Int = 400) -> String {
        MarkdownPatterns.stripMarkdown(String(body.prefix(maxLength)))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
