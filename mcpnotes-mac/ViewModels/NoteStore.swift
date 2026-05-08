import Foundation
import Observation

enum IndexingState {
    case idle
    case indexing(indexed: Int, total: Int)
    case ready(count: Int)
    case failed
}

/// Central data store for all notes. Injected as an environment object
/// so every view in the hierarchy shares the same instance.
@Observable
final class NoteStore {
    var notes: [Note] = []
    var selectedNoteID: UUID?
    var indexingState: IndexingState = .idle

    private var bookmarkedIDs: Set<UUID> = []
    private let fileService: any FileServicing
    private let indexer: any NoteIndexing

    init(fileService: any FileServicing = FileService(),
         indexer: any NoteIndexing = NoteIndexer()) {
        self.fileService = fileService
        self.indexer = indexer
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
        bookmarkedIDs = BookmarkService.loadBookmarks()
        do {
            notes = try fileService.loadAllNotes(bookmarkedIDs: bookmarkedIDs)
        } catch {
            // TODO: surface error to user
        }
        await indexer.loadFromDisk()
        let currentCount = await indexer.indexedCount()
        let total = notes.count
        if total > 0 && currentCount >= total {
            indexingState = .ready(count: currentCount)
        } else {
            indexingState = .indexing(indexed: currentCount, total: total)
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
                while case .indexing(_, let t) = indexingState {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard case .indexing = indexingState else { break }
                    indexingState = .indexing(indexed: await indexer.indexedCount(), total: t)
                }
            }
        }
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
        notes[index] = updated
        Task {
            // TODO: surface errors to user
            try? fileService.saveNote(updated)
            try? await indexer.indexNote(updated)
        }
    }

    func deleteNote(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if selectedNoteID == note.id {
            selectedNoteID = notes.first?.id
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

    // MARK: - Search

    func search(query: String, limit: Int = 10) async throws -> [UUID] {
        try await indexer.search(query: query, limit: limit)
    }

    func searchRanked(query: String, limit: Int = 10) async throws -> [(id: UUID, score: Float)] {
        try await indexer.searchRanked(query: query, limit: limit)
    }

    // MARK: - Bookmarks

    func toggleBookmark(for noteID: UUID) {
        BookmarkService.toggle(id: noteID, in: &bookmarkedIDs)
        if let index = notes.firstIndex(where: { $0.id == noteID }) {
            notes[index].isBookmarked.toggle()
        }
    }

    // MARK: - Private

    private func sortNotes() {
        notes.sort { $0.filename.localizedCompare($1.filename) == .orderedAscending }
    }
}
