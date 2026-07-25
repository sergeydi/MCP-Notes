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
@Observable
final class NoteStore {
    var notes: [Note] = [] {
        didSet { rebuildAllTags() }
    }
    /// True until the initial cold-start load completes; drives a preloader in ContentView.
    /// Stays visible for at least 1s even on fast (non-iCloud) loads to avoid a flash.
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
    private var noteIndexQueue: [Note] = []
    private var indexWorkerTask: Task<Void, Never>?

    init(fileService: any FileServicing = FileService(),
                indexer: any NoteIndexing) {
        self.fileService = fileService
        self.indexer = indexer
    }

    deinit {
        directoryWatcher?.cancel()
        // watcherFD is closed by setCancelHandler — do not close it here
        for source in fileWatchers.values { source.cancel() }
        reloadTask?.cancel()
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID }
    }

    private(set) var allTags: [String] = []

    var bookmarkedNotes: [Note] {
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
                try await fs.loadAllNotes()
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

        let total = notes.count
        if total > 0 {
            indexingState = .indexing(indexed: await indexer.indexedCount(), total: total)
            enqueueNotes(notes)
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

    // MARK: - CRUD

    func createNote() async {
        do {
            let note = try fileService.createNote(baseName: "New Note")
            notes.append(note)
            sortNotes()
            watchFiles([note])
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
        notes[index] = merged
        sortNotes()
        Task {
            // TODO: surface errors to user
            try? fileService.saveNote(merged)
            watchFiles([merged])
            try? await indexer.indexNote(merged)
            indexingState = .ready(count: await indexer.indexedCount())
        }
    }

    func deleteNote(_ note: Note) {
        stopWatchingFile(id: note.id)
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

    func renameNote(_ note: Note, to newName: String, onComplete: (@MainActor (_ updatedNoteFilenames: [String]) -> Void)? = nil) {
        guard !newName.isEmpty else { return }
        let oldName = note.filename
        Task { @MainActor in
            isRenaming = true
            defer { isRenaming = false }

            // TODO: surface errors to user
            guard let renamed = try? fileService.renameNote(note, to: newName) else {
                onComplete?([])
                return
            }
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = renamed
                sortNotes()
            }
            watchFiles([renamed])
            try? await indexer.indexNote(renamed)

            let pattern = /\[\[([^\]]+)\]\]/
            var updatedFilenames: [String] = []
            let snapshot = notes.filter { $0.id != note.id }
            for var n in snapshot {
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
                if let idx = notes.firstIndex(where: { $0.id == n.id }) {
                    notes[idx] = n
                }
                updatedFilenames.append(n.filename)
                try? fileService.saveNote(n)
                watchFiles([n])
                try? await indexer.indexNote(n)
            }
            indexingState = .ready(count: await indexer.indexedCount())
            onComplete?(updatedFilenames)
        }
    }

    /// Stops the directory watcher, clears in-memory state, and reloads from the current
    /// `FileService.notesDirectoryURL`. Call after changing the notes directory.
    func switchDirectory() async {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        stopWatchingAllFiles()
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
        let note = notes[index]
        Task { try? fileService.saveNote(note) }
    }

    // MARK: - Private

    /// Appends notes to the per-note index queue, deduplicating by ID, and starts the
    /// worker task if it is not already running. The worker calls indexNoteIfChanged()
    /// so notes whose body and tags haven't changed are skipped without ML inference.
    private func enqueueNotes(_ notes: [Note]) {
        for note in notes {
            noteIndexQueue.removeAll { $0.id == note.id }
            noteIndexQueue.append(note)
        }
        guard indexWorkerTask == nil else { return }
        indexWorkerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var processed = 0
            while !self.noteIndexQueue.isEmpty {
                let note = self.noteIndexQueue.removeFirst()
                processed += 1
                try? await self.indexer.indexNoteIfChanged(note)
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
    private func watchFiles(_ notesToWatch: [Note]) {
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
        guard let freshNotes = try? await fileService.loadAllNotes() else { return }

        let currentMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let freshMap = Dictionary(freshNotes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let currentIDs = Set(currentMap.keys)
        let freshIDs = Set(freshMap.keys)

        let removedIDs = currentIDs.subtracting(freshIDs)
        let addedIDs = freshIDs.subtracting(currentIDs)
        let changedNotes = freshNotes.filter { fresh in
            guard let current = currentMap[fresh.id] else { return false }
            return current.body != fresh.body || current.tags != fresh.tags || current.filename != fresh.filename
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

        // Enqueue only added and changed notes; unchanged notes are skipped by indexNoteIfChanged.
        let toIndex = addedIDs.compactMap { freshMap[$0] } + changedNotes
        if !toIndex.isEmpty {
            let indexed = await indexer.indexedCount()
            indexingState = .indexing(indexed: indexed, total: indexed + toIndex.count)
            enqueueNotes(toIndex)
        } else if !removedIDs.isEmpty {
            indexingState = .ready(count: await indexer.indexedCount())
        }
    }
}
