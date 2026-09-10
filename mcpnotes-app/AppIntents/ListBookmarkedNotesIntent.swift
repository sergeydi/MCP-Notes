import AppIntents
import Foundation

/// Lets Siri/Shortcuts list bookmarked notes without opening the app.
struct ListBookmarkedNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "List Bookmarked Notes"
    static var description = IntentDescription("Lists bookmarked notes in MCP Notes.")

    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> & ProvidesDialog {
        let notes = try await FileService().loadAllNotes()
        let bookmarked = notes
            .filter(\.isBookmarked)
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
            .map(NoteEntity.init(note:))

        guard !bookmarked.isEmpty else {
            return .result(value: [], dialog: IntentDialog("No bookmarked notes."))
        }

        let titles = bookmarked.map(\.title).joined(separator: ", ")
        let dialog = bookmarked.count == 1
            ? IntentDialog("1 bookmarked note: \(titles).")
            : IntentDialog("\(bookmarked.count) bookmarked notes: \(titles).")
        return .result(value: bookmarked, dialog: dialog)
    }
}
