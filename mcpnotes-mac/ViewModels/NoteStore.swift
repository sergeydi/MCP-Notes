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
    var notes: [Note] = []
    var indexingState: IndexingState = .idle

    // Navigation history — back/forward like a browser
    @ObservationIgnored private var navHistory: [UUID] = []
    @ObservationIgnored private var navIndex: Int = -1
    @ObservationIgnored private var isNavigating: Bool = false

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
    private var reloadTask: Task<Void, Never>?

    init(fileService: any FileServicing = FileService(),
         indexer: any NoteIndexing = NoteIndexer()) {
        self.fileService = fileService
        self.indexer = indexer
    }

    deinit {
        directoryWatcher?.cancel()
        if watcherFD >= 0 { close(watcherFD) }
        reloadTask?.cancel()
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID }
    }

    var allTags: [String] {
        Array(Set(notes.flatMap(\.tags))).sorted()
    }

    var bookmarkedNotes: [Note] {
        notes.filter(\.isBookmarked)
    }

    // MARK: - Loading

    func load() async {
        do {
            notes = try fileService.loadAllNotes()
        } catch {
            // TODO: surface error to user
        }
        await indexer.loadFromDisk()
        let total = notes.count
        if total > 0 {
            indexingState = .indexing(indexed: await indexer.indexedCount(), total: total)
            let snapshot = notes
            Task {
                do {
                    try await indexer.indexAll(snapshot)
                    indexingState = .ready(count: await indexer.indexedCount())
                } catch {
                    indexingState = .failed
                }
            }
            Task {
                while case .indexing = indexingState {
                    try? await Task.sleep(for: .milliseconds(500))
                    let count = await indexer.indexedCount()
                    guard case .indexing(_, let t) = indexingState else { break }
                    indexingState = .indexing(indexed: count, total: t)
                }
            }
        } else {
            indexingState = .ready(count: 0)
        }
        startWatchingNotesDirectory()
    }

    // MARK: - CRUD

    func createNote() async {
        do {
            let note = try fileService.createNote(baseName: "New Note")
            notes.append(note)
            sortNotes()
            selectedNoteID = note.id
            try? await indexer.indexNote(note)
        } catch {
            // TODO: surface error to user
        }
    }

    func updateNote(_ updated: Note) {
        guard let index = notes.firstIndex(where: { $0.id == updated.id }) else { return }
        var merged = updated
        merged.isBookmarked = notes[index].isBookmarked
        notes[index] = merged
        Task {
            // TODO: surface errors to user
            try? fileService.saveNote(merged)
            try? await indexer.indexNote(merged)
        }
    }

    func deleteNote(_ note: Note) {
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
        }
    }

    func renameNote(_ note: Note, to newName: String) {
        guard !newName.isEmpty else { return }
        Task {
            // TODO: surface errors to user
            if let renamed = try? fileService.renameNote(note, to: newName) {
                if let index = notes.firstIndex(where: { $0.id == note.id }) {
                    notes[index] = renamed
                    sortNotes()
                }
                try? await indexer.indexNote(renamed)
            }
        }
    }

    func reindexAll() async {
        guard !notes.isEmpty else { return }
        await indexer.resetAndClearIndex()
        let snapshot = notes
        indexingState = .indexing(indexed: 0, total: snapshot.count)
        Task {
            do {
                try await indexer.indexAll(snapshot)
                indexingState = .ready(count: await indexer.indexedCount())
            } catch {
                indexingState = .failed
            }
        }
        Task {
            while case .indexing = indexingState {
                try? await Task.sleep(for: .milliseconds(500))
                let count = await indexer.indexedCount()
                guard case .indexing(_, let t) = indexingState else { break }
                indexingState = .indexing(indexed: count, total: t)
            }
        }
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

    private func sortNotes() {
        notes.sort { $0.filename.localizedCompare($1.filename) == .orderedAscending }
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

    func scheduleExternalReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.reloadExternalChanges()
        }
    }

    func reloadExternalChanges() async {
        guard let freshNotes = try? fileService.loadAllNotes() else { return }

        let currentMap = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let freshMap = Dictionary(uniqueKeysWithValues: freshNotes.map { ($0.id, $0) })
        let currentIDs = Set(currentMap.keys)
        let freshIDs = Set(freshMap.keys)

        let removedIDs = currentIDs.subtracting(freshIDs)
        let addedIDs = freshIDs.subtracting(currentIDs)
        let changedNotes = freshNotes.filter { fresh in
            guard let current = currentMap[fresh.id] else { return false }
            return current.body != fresh.body || current.tags != fresh.tags || current.filename != fresh.filename
        }

        guard !removedIDs.isEmpty || !addedIDs.isEmpty || !changedNotes.isEmpty else { return }

        for id in removedIDs {
            notes.removeAll { $0.id == id }
            await indexer.removeNote(id: id)
        }
        for note in changedNotes {
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx] = note
            }
            try? await indexer.indexNote(note)
        }
        for id in addedIDs {
            if let note = freshMap[id] {
                notes.append(note)
                try? await indexer.indexNote(note)
            }
        }
        sortNotes()
    }
}
