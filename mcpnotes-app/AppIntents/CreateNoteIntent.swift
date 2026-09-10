import AppIntents
import Foundation

/// Lets Siri/Shortcuts create a note without opening the app. Writes straight through
/// `FileService`, like `ImportSettingsView` does for imported files — `NoteStore`'s directory
/// watcher picks up the new file and reflects it in the UI if the app happens to be running.
struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Note"
    static var description = IntentDescription("Creates a new note in MCP Notes.")

    @Parameter(title: "Title")
    var noteTitle: String

    // Titled "Body", not "Content" — the app's own Localizable.xcstrings already has a
    // "Content" key for the search-results section header ("По содержимому"/"За вмістом"), and
    // App Intents resolves parameter titles against the same string catalog by source string,
    // so "Content" here would render that unrelated translation on this field instead.
    @Parameter(title: "Body")
    var content: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a note titled \(\.$noteTitle)") {
            \.$content
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let trimmedTitle = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NoteFilenameValidator.validate(trimmedTitle) == .valid else {
            throw $noteTitle.needsValueError(
                IntentDialog("What should I call the note? Use only letters, numbers, spaces, and - _ .")
            )
        }

        let fileService = FileService()
        var note = try fileService.createNote(baseName: trimmedTitle)
        if let content, !content.isEmpty {
            note.body = content
            try fileService.saveNote(note)
        }
        return .result(value: NoteEntity(note: note), dialog: "Created note \u{201C}\(note.filename)\u{201D}.")
    }
}
