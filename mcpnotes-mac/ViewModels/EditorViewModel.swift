import Foundation
import Observation

/// Manages the transient editing state for a single note, including
/// debounced autosave to avoid writing on every keystroke.
@Observable
final class EditorViewModel {
    var body: String = ""
    var tags: [String] = []
    private(set) var noteID: UUID?

    var onSave: ((_ body: String, _ tags: [String]) -> Void)?

    private var autosaveTask: Task<Void, Never>?

    /// Loads a note into the editor, resetting any pending autosave.
    func load(note: Note) {
        autosaveTask?.cancel()
        noteID = note.id
        body = note.body
        tags = note.tags
    }

    /// Resets the autosave timer. Call this whenever `body` or `tags` change.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            onSave?(body, tags)
        }
    }

    /// Flushes any pending autosave immediately (e.g., on view disappear).
    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        onSave?(body, tags)
    }
}
