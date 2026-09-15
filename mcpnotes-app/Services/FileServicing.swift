import Foundation

public protocol FileServicing {
    /// Loads every note with its full body. Used by `AppIntents/*` (their own `FileService`
    /// instance, outside `NoteStore`), which genuinely need every note's content at once.
    func loadAllNotes() async throws -> [Note]
    /// Loads metadata (no body) for every note — what `NoteStore.notes` stays populated with.
    func loadAllNotesMetadata() async throws -> [NoteMetadata]
    /// Loads a single note's full content on demand (e.g. when opening it in the editor).
    func loadNote(at fileURL: URL) async throws -> Note
    func saveNote(_ note: Note) throws
    func createNote(baseName: String) throws -> Note
    /// Flips the `bookmarked` frontmatter flag without requiring the caller to hold the body.
    func setBookmarked(_ isBookmarked: Bool, at fileURL: URL) throws
    func deleteNote(_ metadata: NoteMetadata) throws
    func renameNote(_ metadata: NoteMetadata, to newName: String) throws -> NoteMetadata
}
