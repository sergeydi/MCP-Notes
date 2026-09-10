import AppIntents
import Foundation

/// Lets Siri/Shortcuts bookmark or unbookmark a note by name without opening the app.
struct ToggleBookmarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Note Bookmark"
    static var description = IntentDescription("Adds or removes a note from Bookmarks in MCP Notes.")

    @Parameter(title: "Note")
    var target: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle bookmark for \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let fileService = FileService()
        let notes = try await fileService.loadAllNotes()
        guard var note = notes.first(where: { $0.id == target.id }) else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }

        note.isBookmarked.toggle()
        try fileService.saveNote(note)

        let dialog: IntentDialog = note.isBookmarked
            ? IntentDialog("Bookmarked \u{201C}\(note.filename)\u{201D}.")
            : IntentDialog("Removed \u{201C}\(note.filename)\u{201D} from bookmarks.")
        return .result(value: NoteEntity(note: note), dialog: dialog)
    }
}
