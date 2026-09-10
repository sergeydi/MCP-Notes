import AppIntents
import Foundation

/// Represents a note to Siri, Spotlight, and the Shortcuts app. Identified by the note's `uid`
/// frontmatter field (`Note.id`), so an entity handed back by Siri stays valid across renames.
struct NoteEntity: AppEntity {
    let id: UUID
    let title: String
    let snippet: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static var defaultQuery = NoteEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(snippet)")
    }

    init(note: Note) {
        id = note.id
        title = note.filename
        let stripped = MarkdownPatterns.stripMarkdown(note.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        snippet = String(stripped.prefix(80))
    }
}

/// Looks up notes for Siri/Shortcuts by reading directly from disk via `FileService`, the same
/// way the MCP server (a separate process with no access to `NoteStore`'s in-memory state) reads
/// notes — an App Intent can run in the background before `NoteStore.load()` has populated anything.
struct NoteEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [NoteEntity.ID]) async throws -> [NoteEntity] {
        let notes = try await FileService().loadAllNotes()
        return notes
            .filter { identifiers.contains($0.id) }
            .map(NoteEntity.init(note:))
    }

    func suggestedEntities() async throws -> [NoteEntity] {
        let notes = try await FileService().loadAllNotes()
        return notes
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(10)
            .map(NoteEntity.init(note:))
    }

    /// Title-only match, mirroring `mcpnotes-server`'s `find_note` tool — lets Siri/Shortcuts
    /// resolve `OpenNoteIntent`'s `target` parameter by the name the user types or speaks.
    func entities(matching string: String) async throws -> [NoteEntity] {
        let lowercased = string.lowercased()
        let notes = try await FileService().loadAllNotes()
        return notes
            .filter { $0.filename.lowercased().contains(lowercased) }
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
            .map(NoteEntity.init(note:))
    }
}
