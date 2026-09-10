import AppIntents
import Foundation

/// Lets Siri/Shortcuts add text to an existing note without opening the app — "add to my note
/// X: buy milk". Appends rather than replacing `body`, unlike `mcpnotes-server`'s `update_note`
/// tool (which overwrites the whole body); a voice command should never risk wiping a note.
struct AppendToNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Note"
    static var description = IntentDescription("Appends text to the end of an existing note in MCP Notes.")

    @Parameter(title: "Note")
    var target: NoteEntity

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let fileService = FileService()
        let notes = try await fileService.loadAllNotes()
        guard var note = notes.first(where: { $0.id == target.id }) else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }

        if note.body.isEmpty {
            note.body = text
        } else {
            note.body += note.body.hasSuffix("\n") ? "\n\(text)" : "\n\n\(text)"
        }
        try fileService.saveNote(note)

        return .result(value: NoteEntity(note: note), dialog: "Added to \u{201C}\(note.filename)\u{201D}.")
    }
}
