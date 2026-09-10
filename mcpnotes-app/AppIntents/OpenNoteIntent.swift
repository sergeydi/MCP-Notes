import AppIntents
import Foundation

/// Lets Siri/Shortcuts open a specific note by name. Brings the app to the foreground
/// (`openAppWhenRun`) and hands the target off via `PendingNoteNavigation` rather than mutating
/// `NoteStore` directly, since this intent may run in a different process instance than the one
/// that becomes visible to the user.
struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Note"
    static var description = IntentDescription("Opens a note in MCP Notes.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Note")
    var target: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        let notes = try await FileService().loadAllNotes()
        guard notes.contains(where: { $0.id == target.id }) else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }
        PendingNoteNavigation.request(target.id)
        return .result()
    }
}
