import Foundation
import Observation

enum IndexingState {
    case idle
    case indexing(indexed: Int, total: Int)
    case ready(count: Int)
    case failed

    var isIndexing: Bool {
        if case .indexing = self { return true }
        return false
    }
}

/// Central data store for all notes. Injected as an environment object
/// so every view in the hierarchy shares the same instance.
///
/// `notes` holds only metadata — no body — for every note, always. Full note content (`body`)
/// is loaded from disk on demand (`loadFullNote(_:)`) and expected to be resident for at most
/// one note at a time: the note open in the editor, or transiently inside a loop that reads,
/// checks, and discards one note's body before moving to the next (rename cascade, indexing
/// worker). See CLAUDE.md's NoteStore section for the full design rationale.
@Observable
final class NoteStore {
    var notes: [NoteMetadata] = [] {
        didSet { rebuildAllTags() }
    }
    /// True until the initial cold-start load completes; drives a small spinner in
    /// SidebarView's toolbar. The note list itself is shown immediately, so this never
    /// blocks already-loaded notes from appearing.
    /// Stays true for at least 1s even on fast (non-iCloud) loads to avoid a flash.
    var isLoading: Bool = true
    var indexingState: IndexingState = .idle
    /// True when the search index had to be rebuilt due to corruption or inconsistency.
    /// Cleared when the user manually triggers a full re-index.
    var indexWasRecovered: Bool = false

    // Navigation history — back/forward like a browser
    @ObservationIgnored private var navHistory: [UUID] = []
    @ObservationIgnored private var navIndex: Int = -1
    @ObservationIgnored private var isNavigating: Bool = false
    @ObservationIgnored private var isRenaming: Bool = false

    private(set) var canNavigateBack: Bool = false
    private(set) var canNavigateForward: Bool = false

    @ObservationIgnored private var _selectedNoteID: UUID?
    var selectedNoteID: UUID? {
        get {
            access(keyPath: \.selectedNoteID)
            return _selectedNoteID
        }
        set {
            withMutation(keyPath: \.selectedNoteID) {
                let old = _selectedNoteID
                _selectedNoteID = newValue
                if !isNavigating, let id = newValue, id != old {
                    if navIndex < navHistory.count - 1 {
                        navHistory = Array(navHistory.prefix(navIndex + 1))
                    }
                    navHistory.append(id)
                    navIndex = navHistory.count - 1
                    updateNavState()
                }
            }
        }
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        isNavigating = true
        navIndex -= 1
        selectedNoteID = navHistory[navIndex]
        isNavigating = false
        updateNavState()
    }

    func navigateForward() {
        guard canNavigateForward else { return }
        isNavigating = true
        navIndex += 1
        selectedNoteID = navHistory[navIndex]
        isNavigating = false
        updateNavState()
    }

    private func updateNavState() {
        canNavigateBack = navIndex > 0
        canNavigateForward = navIndex < navHistory.count - 1
    }

    private let fileService: any FileServicing
    private let indexer: any NoteIndexing

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    // Per-note file watchers. The directory-level watcher only fires on dirent changes
    // (add/remove/rename) — a plain in-place write to an existing file's contents (which is
    // how iCloud sync sometimes updates an already-materialized note) never touches the
    // directory's own vnode and is invisible to it. Watching each note's file directly closes
    // that gap. Any write — ours or iCloud's — that replaces the file atomically also swaps
    // out the underlying inode, which stales the open fd, so watchers are always torn down
    // and reopened rather than reused.
    private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var reloadTask: Task<Void, Never>?
    private var noteIndexQueue: [NoteMetadata] = []
    private var indexWorkerTask: Task<Void, Never>?
    // Per-note debounce for handing an edited note off to the (expensive, ML-backed) indexer —
    // separate from EditorViewModel's own 1s autosave-to-disk debounce. Without this, a note
    // that keeps getting edited in bursts more than 1s apart would re-embed on every single
    // pause; this only enqueues once edits actually stop for `indexDebounceDuration`.
    private var indexDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private let indexDebounceDuration: Duration

    init(fileService: any FileServicing = FileService(),
                indexer: any NoteIndexing,
                indexDebounceDuration: Duration = .seconds(300)) {
        self.fileService = fileService
        self.indexer = indexer
        self.indexDebounceDuration = indexDebounceDuration
    }

    deinit {
        directoryWatcher?.cancel()
        // watcherFD is closed by setCancelHandler — do not close it here
        for source in fileWatchers.values { source.cancel() }
        reloadTask?.cancel()
        for task in indexDebounceTasks.values { task.cancel() }
    }

    var selectedNote: NoteMetadata? {
        notes.first { $0.id == selectedNoteID }
    }

    private(set) var allTags: [String] = []

    var bookmarkedNotes: [NoteMetadata] {
        notes.filter(\.isBookmarked)
    }

    // MARK: - Loading

    func load() async {
        let start = ContinuousClock.now
        await loadNotes()
        dismissLoadingIndicator(after: start)
    }

    private func loadNotes() async {
        do {
            // Resolving the notes directory can block for a while on first access
            // (e.g. FileManager.url(forUbiquityContainerIdentifier:) establishing the
            // iCloud container) — run off the main actor so app launch never stalls
            // long enough to trip the system's scene-creation watchdog.
            let fs = fileService
            notes = try await Task.detached(priority: .userInitiated) {
                try await fs.loadAllNotesMetadata()
            }.value
        } catch {
            indexingState = .failed
            return
        }
        let recovered = await indexer.loadFromDisk()
        if recovered { indexWasRecovered = true }

        // Remove index entries for notes deleted while the app was closed.
        let loadedIDs = Set(notes.map(\.id))
        let orphanedIDs = await indexer.allIndexedIDs().subtracting(loadedIDs)
        for id in orphanedIDs { await indexer.removeNote(id: id) }

        if !notes.isEmpty {
            scheduleIndexing(for: notes)
        } else {
            indexingState = .ready(count: 0)
        }
        startWatchingNotesDirectory()
        watchFiles(notes)
    }

    /// Clears `isLoading`, holding the preloader up to a 1s minimum so it never just flashes.
    /// Runs detached from `load()` so callers (incl. tests) awaiting `load()` aren't delayed.
    private func dismissLoadingIndicator(after start: ContinuousClock.Instant) {
        let minimumDuration = Duration.seconds(1)
        let elapsed = ContinuousClock.now - start
        guard elapsed < minimumDuration else {
            isLoading = false
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: minimumDuration - elapsed)
            self?.isLoading = false
        }
    }

    /// Loads a note's full content on demand — the only place in the app that should hold a
    /// note's `body` for longer than a single local scope (the editor, for as long as that
    /// note stays open).
    func loadFullNote(_ metadata: NoteMetadata) async throws -> Note {
        try await fileService.loadNote(at: metadata.fileURL)
    }

    // MARK: - CRUD

    func createNote() async {
        do {
            let note = try fileService.createNote(baseName: "New Note")
            let metadata = NoteMetadata(note)
            notes.append(metadata)
            sortNotes()
            watchFiles([metadata])
            selectedNoteID = note.id
            try? await indexer.indexNote(note)
            indexingState = .ready(count: await indexer.indexedCount())
        } catch {
            // TODO: surface error to user
        }
    }

    func updateNote(_ updated: Note) {
        guard let index = notes.firstIndex(where: { $0.id == updated.id }) else { return }
        var merged = updated
        merged.isBookmarked = notes[index].isBookmarked
        notes[index] = NoteMetadata(merged)
        sortNotes()
        Task {
            // TODO: surface errors to user
            try? fileService.saveNote(merged)
            guard let idx = notes.firstIndex(where: { $0.id == merged.id }) else { return }
            // Refresh modifiedAt from the file we just wrote so the next external-reload
            // tick (mtime diff) doesn't mistake our own save for an external change.
            if let mtime = try? merged.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                notes[idx].modifiedAt = mtime
            }
            watchFiles([notes[idx]])
            scheduleIndexing(for: notes[idx])
        }
    }

    func deleteNote(_ note: NoteMetadata) {
        stopWatchingFile(id: note.id)
        indexDebounceTasks.removeValue(forKey: note.id)?.cancel()
        notes.removeAll { $0.id == note.id }

        navHistory.removeAll { $0 == note.id }
        navIndex = navHistory.isEmpty ? -1 : min(navIndex, navHistory.count - 1)
        updateNavState()

        if selectedNoteID == note.id {
            isNavigating = true
            selectedNoteID = navIndex >= 0 ? navHistory[navIndex] : notes.first?.id
            isNavigating = false
        }

        Task {
            // TODO: surface errors to user
            try? fileService.deleteNote(note)
            await indexer.removeNote(id: note.id)
            indexingState = .ready(count: await indexer.indexedCount())
        }
    }

    func renameNote(_ note: NoteMetadata, to newName: String, onComplete: (@MainActor (_ updatedNoteFilenames: [String]) -> Void)? = nil) {
        guard !newName.isEmpty else { return }
        let oldName = note.filename
        Task { @MainActor in
            isRenaming = true
            defer { isRenaming = false }

            // TODO: surface errors to user
            guard let renamedMetadata = try? fileService.renameNote(note, to: newName) else {
                onComplete?([])
                return
            }
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = renamedMetadata
                sortNotes()
            }
            watchFiles([renamedMetadata])
            var notesToEnqueue = [renamedMetadata]

            let pattern = /\[\[([^\]]+)\]\]/
            var updatedFilenames: [String] = []
            // Read/check/save one candidate at a time so at most one other note's body is
            // ever resident in memory during the cascade, regardless of vault size.
            let candidates = notes.filter { $0.id != note.id }
            for metadata in candidates {
                guard var n = try? await fileService.loadNote(at: metadata.fileURL) else { continue }
                var mutated = false
                let newBody = n.body.replacing(pattern) { match in
                    let inner = match.output.1.trimmingCharacters(in: .whitespaces)
                    guard inner.lowercased() == oldName.lowercased() else {
                        return String(match.output.0)
                    }
                    mutated = true
                    return "[[\(newName)]]"
                }
                guard mutated else { continue }
                n.body = newBody
                try? fileService.saveNote(n)
                let updatedMetadata = NoteMetadata(n)
                if let idx = notes.firstIndex(where: { $0.id == n.id }) {
                    notes[idx] = updatedMetadata
                }
                watchFiles([updatedMetadata])
                updatedFilenames.append(n.filename)
                notesToEnqueue.append(updatedMetadata)
            }
            // Indexing runs off the rename path through the same per-note debounce as edits
            // (see scheduleIndexing) so the rename itself isn't blocked on ML embedding.
            scheduleIndexing(for: notesToEnqueue)
            onComplete?(updatedFilenames)
        }
    }

    /// Stops the directory watcher, clears in-memory state, and reloads from the current
    /// `FileService.notesDirectoryURL`. Call after changing the notes directory.
    func switchDirectory() async {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        stopWatchingAllFiles()
        for task in indexDebounceTasks.values { task.cancel() }
        indexDebounceTasks.removeAll()
        notes = []
        selectedNoteID = nil
        navHistory = []
        navIndex = -1
        updateNavState()
        indexingState = .idle
        indexWasRecovered = false
        await load()
    }

    func reindexAll() async {
        guard !notes.isEmpty else { return }
        indexWasRecovered = false
        await indexer.resetAndClearIndex()
        indexingState = .indexing(indexed: 0, total: notes.count)
        enqueueNotes(notes)
    }

    // MARK: - Search

    func search(query: String, limit: Int = 10) async throws -> [UUID] {
        try await indexer.search(query: query, limit: limit)
    }

    func searchRanked(query: String, limit: Int = 10) async throws -> [(id: UUID, score: Float)] {
        try await indexer.searchRanked(query: query, limit: limit)
    }

    /// Plain-substring "Content" search: reads candidate notes' bodies from disk one at a time,
    /// checking for a match and discarding the body immediately after — never holds more than
    /// one candidate's body in memory, and preserves exact substring semantics (unlike a
    /// token-based FTS index) on both platforms.
    func searchNoteBodies(query: String, in candidates: [NoteMetadata]) async -> [BodySearchMatch] {
        guard !query.isEmpty else { return [] }
        let lowerQuery = query.lowercased()
        var results: [BodySearchMatch] = []
        for metadata in candidates {
            guard let note = try? await fileService.loadNote(at: metadata.fileURL) else { continue }
            if let match = SnippetBuilder.match(in: note.body, query: query) {
                results.append(BodySearchMatch(metadata: metadata, match: match))
            } else if metadata.tags.contains(where: { $0.lowercased().contains(lowerQuery) }) {
                results.append(BodySearchMatch(metadata: metadata, match: nil))
            }
            // `note` goes out of scope here — at most one body in memory during this loop.
        }
        return results
    }

    func outgoingLinks(from noteID: UUID) async -> [UUID] {
        await indexer.outgoingLinks(from: noteID)
    }

    func incomingLinks(to noteID: UUID) async -> [UUID] {
        await indexer.incomingLinks(to: noteID)
    }

    func allWikilinkEdges() async -> [(source: UUID, target: UUID)] {
        await indexer.allLinks()
    }

    // MARK: - Bookmarks

    func toggleBookmark(for noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].isBookmarked.toggle()
        let metadata = notes[index]
        Task {
            try? fileService.setBookmarked(metadata.isBookmarked, at: metadata.fileURL)
            watchFiles([metadata])
        }
    }

    // MARK: - Private

    /// Debounces handing off a batch of notes to `scheduleIndexing(for: NoteMetadata)` — used by
    /// cold-start load, the rename wikilink cascade, and external-change reloads, so none of
    /// those paths bypass the per-note debounce below.
    private func scheduleIndexing(for notesToSchedule: [NoteMetadata]) {
        for note in notesToSchedule {
            scheduleIndexing(for: note)
        }
    }

    /// Debounces handing a note to `enqueueNotes` by `indexDebounceDuration` — separate from
    /// `EditorViewModel`'s own 1s autosave-to-disk debounce: the note is already saved to disk
    /// by the time this runs (or, for load/rename/external-change callers, was never dirty to
    /// begin with), so cancelling and rescheduling here only delays the (costly) ML embedding
    /// step. Rescheduling this same note (an edit, a rename, another external change) within the
    /// debounce window resets the timer, so it only gets enqueued once things settle.
    private func scheduleIndexing(for metadata: NoteMetadata) {
        indexDebounceTasks[metadata.id]?.cancel()
        indexDebounceTasks[metadata.id] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.indexDebounceDuration)
            guard !Task.isCancelled else { return }
            self.indexDebounceTasks[metadata.id] = nil
            // Look up fresh in case the note was renamed/edited again while we were waiting.
            guard let current = self.notes.first(where: { $0.id == metadata.id }) else { return }
            let indexed = await self.indexer.indexedCount()
            self.indexingState = .indexing(indexed: indexed, total: indexed + 1)
            self.enqueueNotes([current])
        }
    }

    /// Appends notes to the per-note index queue, deduplicating by ID, and starts the
    /// worker task if it is not already running. The worker reads each note's body from disk
    /// immediately before indexing it (never holding more than one body at a time, even during
    /// a full cold-start index of a large vault) and calls indexNoteIfChanged() so notes whose
    /// body and tags haven't changed are skipped without ML inference.
    private func enqueueNotes(_ notes: [NoteMetadata]) {
        for note in notes {
            noteIndexQueue.removeAll { $0.id == note.id }
            noteIndexQueue.append(note)
        }
        guard indexWorkerTask == nil else { return }
        // .utility: visible progress (settings-icon indicator) but shouldn't compete with
        // UI-critical work for scheduling.
        indexWorkerTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            var processed = 0
            while !self.noteIndexQueue.isEmpty {
                let metadata = self.noteIndexQueue.removeFirst()
                processed += 1
                if let note = try? await self.fileService.loadNote(at: metadata.fileURL) {
                    try? await self.indexer.indexNoteIfChanged(note)
                }
                let remaining = self.noteIndexQueue.count
                if remaining > 0 {
                    self.indexingState = .indexing(indexed: processed, total: processed + remaining)
                }
            }
            self.indexingState = .ready(count: await self.indexer.indexedCount())
            self.indexWorkerTask = nil
        }
    }

    private func sortNotes() {
        notes.sort { $0.filename.localizedCompare($1.filename) == .orderedAscending }
    }

    private func rebuildAllTags() {
        let rebuilt = Array(Set(notes.flatMap(\.tags))).sorted()
        if rebuilt != allTags { allTags = rebuilt }
    }

    // MARK: - File watching

    private func startWatchingNotesDirectory() {
        let dir = FileService.notesDirectoryURL
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleExternalReload()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.watcherFD)
            self.watcherFD = -1
        }
        source.resume()
        directoryWatcher = source
    }

    /// (Re)opens a file-level watcher for each given note, replacing any existing one.
    /// Must be called after any write to a note's file (ours or external) since an atomic
    /// replace swaps the inode out from under the previously open fd.
    private func watchFiles(_ notesToWatch: [NoteMetadata]) {
        for note in notesToWatch {
            stopWatchingFile(id: note.id)
            let fd = open(note.fileURL.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleExternalReload()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            fileWatchers[note.id] = source
        }
    }

    private func stopWatchingFile(id: UUID) {
        fileWatchers.removeValue(forKey: id)?.cancel()
    }

    private func stopWatchingAllFiles() {
        for source in fileWatchers.values { source.cancel() }
        fileWatchers.removeAll()
    }

    func scheduleExternalReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.reloadExternalChanges()
        }
    }

    func reloadExternalChanges() async {
        guard !isRenaming else { return }
        guard let freshNotes = try? await fileService.loadAllNotesMetadata() else { return }

        let currentMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let freshMap = Dictionary(freshNotes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let currentIDs = Set(currentMap.keys)
        let freshIDs = Set(freshMap.keys)

        let removedIDs = currentIDs.subtracting(freshIDs)
        let addedIDs = freshIDs.subtracting(currentIDs)
        // mtime changes on every write (body, tags, or bookmark — see FrontmatterParser/
        // FileService), so it's a correct proxy for "content changed" without reading the file.
        let changedNotes = freshNotes.filter { fresh in
            guard let current = currentMap[fresh.id] else { return false }
            return current.modifiedAt != fresh.modifiedAt
                || current.filename != fresh.filename
                || current.tags != fresh.tags
                || current.isBookmarked != fresh.isBookmarked
        }

        guard !removedIDs.isEmpty || !addedIDs.isEmpty || !changedNotes.isEmpty else { return }

        // Apply diff to in-memory notes array.
        for id in removedIDs {
            notes.removeAll { $0.id == id }
        }
        for note in changedNotes {
            if let idx = notes.firstIndex(where: { $0.id == note.id }) { notes[idx] = note }
        }
        for id in addedIDs {
            if let note = freshMap[id] { notes.append(note) }
        }
        sortNotes()

        // Re-sync file watchers: drop removed notes, (re)open changed/added ones since an
        // external atomic replace invalidates the previously open fd for that note.
        for id in removedIDs { stopWatchingFile(id: id) }
        let notesToWatch = changedNotes + addedIDs.compactMap { freshMap[$0] }
        if !notesToWatch.isEmpty { watchFiles(notesToWatch) }

        // Clean up navigation state for removed notes.
        for id in removedIDs {
            navHistory.removeAll { $0 == id }
        }
        if !removedIDs.isEmpty {
            navIndex = navHistory.isEmpty ? -1 : min(navIndex, navHistory.count - 1)
            updateNavState()
            if let sel = selectedNoteID, removedIDs.contains(sel) {
                isNavigating = true
                selectedNoteID = navIndex >= 0 ? navHistory[navIndex] : notes.first?.id
                isNavigating = false
            }
        }

        // Remove deleted notes from the index directly (fast, no ML inference).
        for id in removedIDs { await indexer.removeNote(id: id) }

        // Debounce indexing added/changed notes; unchanged notes are skipped by indexNoteIfChanged
        // once the debounce fires and hands them to enqueueNotes.
        let toIndex = addedIDs.compactMap { freshMap[$0] } + changedNotes
        if !toIndex.isEmpty {
            scheduleIndexing(for: toIndex)
        } else if !removedIDs.isEmpty {
            indexingState = .ready(count: await indexer.indexedCount())
        }
    }
}

/// A "Content" search hit: the note plus (if the match came from body text) the highlighted
/// context around it. `match` is `nil` when the note matched via a tag instead of its body.
struct BodySearchMatch: Identifiable {
    let metadata: NoteMetadata
    let match: SnippetBuilder.Match?
    var id: UUID { metadata.id }
}
