import AppIntents
import Foundation

/// Lets Siri/Shortcuts search notes without opening the app. Matches title/body/tags the same
/// way `mcpnotes-server`'s `search_notes` tool and iOS's in-app search do (no RAG/semantic
/// ranking — that requires `NoteIndexer`, which is macOS-only and lives in-process in the app).
struct SearchNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Notes"
    static var description = IntentDescription("Searches note titles, content, and tags in MCP Notes.")

    @Parameter(title: "Search Text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search notes for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> & ProvidesDialog {
        let lowercased = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercased.isEmpty else {
            throw $query.needsValueError(IntentDialog("What should I search for?"))
        }

        let notes = try await FileService().loadAllNotes()
        let matches: [NoteEntity] = notes
            .filter { note in
                note.filename.lowercased().contains(lowercased)
                    || note.body.lowercased().contains(lowercased)
                    || note.tags.contains { $0.lowercased().contains(lowercased) }
            }
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
            .prefix(10)
            .map(NoteEntity.init(note:))

        guard !matches.isEmpty else {
            return .result(value: [], dialog: IntentDialog("No notes found matching \u{201C}\(query)\u{201D}."))
        }

        let titles = matches.map(\.title).joined(separator: ", ")
        let dialog = matches.count == 1
            ? IntentDialog("Found 1 note: \(titles).")
            : IntentDialog("Found \(matches.count) notes: \(titles).")
        return .result(value: matches, dialog: dialog)
    }
}
