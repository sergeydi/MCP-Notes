import Foundation
import Observation

/// Manages the transient editing state for a single note, including
/// debounced autosave to avoid writing on every keystroke.
@Observable
public final class EditorViewModel {
    public var body: String = ""
    public var tags: [String] = []
    public private(set) var noteID: UUID?

    public var onSave: ((_ body: String, _ tags: [String]) -> Void)?

    private var autosaveTask: Task<Void, Never>?

    public init() {}

    /// Loads a note into the editor, resetting any pending autosave.
    public func load(note: Note) {
        autosaveTask?.cancel()
        noteID = note.id
        body = note.body
        tags = note.tags
    }

    /// Resets the autosave timer. Call this whenever `body` or `tags` change.
    public func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            onSave?(body, tags)
        }
    }

    /// Flushes any pending autosave immediately (e.g., on view disappear).
    public func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        onSave?(body, tags)
    }

    /// Cancels any pending autosave without saving (e.g., before deletion).
    public func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }
}
