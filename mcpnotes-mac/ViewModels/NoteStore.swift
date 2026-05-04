import Foundation
import Observation

/// Central data store for all notes. Injected as an environment object
/// so every view in the hierarchy shares the same instance.
@Observable
final class NoteStore {
    var notes: [Note] = []
    var selectedNoteID: UUID?

    private var bookmarkedIDs: Set<UUID> = []

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
            notes = try FileService.loadAllNotes(bookmarkedIDs: bookmarkedIDs)
        } catch {
            // TODO: surface error to user
        }
    }

    // MARK: - CRUD

    func createNote() async {
        do {
            let note = try FileService.createNote()
            notes.append(note)
            sortNotes()
            selectedNoteID = note.id
        } catch {
            // TODO: surface error to user
        }
    }

    func updateNote(_ updated: Note) {
        guard let index = notes.firstIndex(where: { $0.id == updated.id }) else { return }
        notes[index] = updated
        Task {
            try? FileService.saveNote(updated)
        }
    }

    func deleteNote(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if selectedNoteID == note.id {
            selectedNoteID = notes.first?.id
        }
        Task {
            try? FileService.deleteNote(note)
        }
    }

    func renameNote(_ note: Note, to newName: String) {
        guard !newName.isEmpty else { return }
        Task {
            if let renamed = try? FileService.renameNote(note, to: newName) {
                if let index = notes.firstIndex(where: { $0.id == note.id }) {
                    notes[index] = renamed
                    sortNotes()
                }
            }
        }
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
