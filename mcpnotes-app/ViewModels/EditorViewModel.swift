import CryptoKit
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
    private var _loadedHash: Insecure.MD5Digest?

    /// True when `body`/`tags` have local changes not yet handed off to `onSave`.
    public var isDirty: Bool {
        contentHash(body: body, tags: tags) != _loadedHash
    }

    public init() {}

    private func contentHash(body: String, tags: [String]) -> Insecure.MD5Digest {
        var hasher = Insecure.MD5()
        hasher.update(data: Data(body.utf8))
        for tag in tags { hasher.update(data: Data(tag.utf8)) }
        return hasher.finalize()
    }

    /// Loads a note into the editor, resetting any pending autosave.
    public func load(note: Note) {
        autosaveTask?.cancel()
        noteID = note.id
        body = note.body
        tags = note.tags
        _loadedHash = contentHash(body: note.body, tags: note.tags)
    }

    /// Resets the autosave timer. Call this whenever `body` or `tags` change.
    public func scheduleAutosave() {
        autosaveTask?.cancel()
        guard isDirty else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            onSave?(body, tags)
            _loadedHash = contentHash(body: body, tags: tags)
        }
    }

    /// Flushes any pending autosave immediately (e.g., on view disappear).
    public func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty else { return }
        onSave?(body, tags)
        _loadedHash = contentHash(body: body, tags: tags)
    }

    /// Cancels any pending autosave without saving (e.g., before deletion).
    public func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }
}
