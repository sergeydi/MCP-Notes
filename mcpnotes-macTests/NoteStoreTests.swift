import Foundation
import Testing
@testable import mcpnotes_mac

@Suite("NoteStore – in-memory")
@MainActor
struct NoteStoreTests {

    func makeNote(
        filename: String = "Test",
        tags: [String] = [],
        isBookmarked: Bool = false
    ) -> Note {
        Note(
            id: UUID(),
            filename: filename,
            tags: tags,
            body: "body",
            fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"),
            isBookmarked: isBookmarked
        )
    }

    // MARK: selectedNote

    @Test func selectedNoteReturnsMatchingNote() {
        let store = NoteStore()
        let note = makeNote()
        store.notes = [note]
        store.selectedNoteID = note.id
        #expect(store.selectedNote?.id == note.id)
    }

    @Test func selectedNoteReturnsNilWhenIDUnknown() {
        let store = NoteStore()
        store.notes = [makeNote()]
        store.selectedNoteID = UUID()
        #expect(store.selectedNote == nil)
    }

    @Test func selectedNoteReturnsNilWhenListEmpty() {
        let store = NoteStore()
        store.selectedNoteID = UUID()
        #expect(store.selectedNote == nil)
    }

    // MARK: allTags

    @Test func allTagsReturnsSortedUniqueValues() {
        let store = NoteStore()
        store.notes = [
            makeNote(tags: ["swift", "macOS"]),
            makeNote(tags: ["swift", "swiftUI"]),
        ]
        #expect(store.allTags == ["macOS", "swift", "swiftUI"])
    }

    @Test func allTagsEmptyWhenNoNotes() {
        let store = NoteStore()
        #expect(store.allTags.isEmpty)
    }

    @Test func allTagsDeduplicatesAcrossNotes() {
        let store = NoteStore()
        store.notes = [makeNote(tags: ["a"]), makeNote(tags: ["a"]), makeNote(tags: ["a"])]
        #expect(store.allTags == ["a"])
    }

    // MARK: bookmarkedNotes

    @Test func bookmarkedNotesFiltersCorrectly() {
        let store = NoteStore()
        let bm = makeNote(isBookmarked: true)
        let normal = makeNote(isBookmarked: false)
        store.notes = [bm, normal]
        #expect(store.bookmarkedNotes.count == 1)
        #expect(store.bookmarkedNotes.first?.id == bm.id)
    }

    @Test func bookmarkedNotesEmptyWhenNoneBookmarked() {
        let store = NoteStore()
        store.notes = [makeNote(), makeNote()]
        #expect(store.bookmarkedNotes.isEmpty)
    }

    // MARK: updateNote

    @Test func updateNoteUpdatesBodyInMemory() {
        let store = NoteStore()
        var note = makeNote()
        store.notes = [note]
        note.body = "Updated"
        store.updateNote(note)
        #expect(store.notes.first?.body == "Updated")
    }

    @Test func updateNoteUpdatesTags() {
        let store = NoteStore()
        var note = makeNote(tags: ["old"])
        store.notes = [note]
        note.tags = ["new"]
        store.updateNote(note)
        #expect(store.notes.first?.tags == ["new"])
    }

    @Test func updateNoteIgnoresUnknownID() {
        let store = NoteStore()
        store.notes = [makeNote(filename: "Real")]
        let ghost = makeNote(filename: "Ghost")
        store.updateNote(ghost)
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.filename == "Real")
    }

    // MARK: deleteNote

    @Test func deleteNoteRemovesFromArray() {
        let store = NoteStore()
        let note = makeNote()
        store.notes = [note]
        store.deleteNote(note)
        #expect(store.notes.isEmpty)
    }

    @Test func deleteSelectedNoteNilsSelection() {
        let store = NoteStore()
        let note = makeNote()
        store.notes = [note]
        store.selectedNoteID = note.id
        store.deleteNote(note)
        #expect(store.selectedNoteID == nil)
    }

    @Test func deleteNoteSelectsFirstRemainingWhenSelected() {
        let store = NoteStore()
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [a, b]
        store.selectedNoteID = b.id
        store.deleteNote(b)
        #expect(store.selectedNoteID == a.id)
    }

    @Test func deleteNoteKeepsSelectionWhenDifferentNoteDeleted() {
        let store = NoteStore()
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [a, b]
        store.selectedNoteID = a.id
        store.deleteNote(b)
        #expect(store.selectedNoteID == a.id)
    }

    // MARK: toggleBookmark

    @Test func toggleBookmarkFlipsFlagOn() {
        let store = NoteStore()
        let note = makeNote(isBookmarked: false)
        store.notes = [note]
        store.toggleBookmark(for: note.id)
        #expect(store.notes.first?.isBookmarked == true)
    }

    @Test func toggleBookmarkFlipsFlagOff() {
        let store = NoteStore()
        let note = makeNote(isBookmarked: true)
        store.notes = [note]
        store.toggleBookmark(for: note.id)
        #expect(store.notes.first?.isBookmarked == false)
    }

    @Test func toggleBookmarkRoundTrip() {
        let store = NoteStore()
        let note = makeNote(isBookmarked: false)
        store.notes = [note]
        store.toggleBookmark(for: note.id)
        store.toggleBookmark(for: note.id)
        #expect(store.notes.first?.isBookmarked == false)
    }
}
