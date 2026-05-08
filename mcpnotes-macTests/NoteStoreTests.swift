import Foundation
import Testing
@testable import mcpnotes_mac

// MARK: - Mocks

@MainActor
final class MockFileService: FileServicing {
    var stubbedNotes: [Note] = []
    private(set) var savedNotes: [Note] = []
    private(set) var deletedNotes: [Note] = []
    private(set) var createdBaseName: String?
    private(set) var renamedTo: String?

    func loadAllNotes(bookmarkedIDs: Set<UUID>) throws -> [Note] { stubbedNotes }
    func saveNote(_ note: Note) throws { savedNotes.append(note) }
    func createNote(baseName: String) throws -> Note {
        createdBaseName = baseName
        return Note(id: UUID(), filename: baseName, tags: [], body: "",
                    fileURL: URL(fileURLWithPath: "/tmp/\(baseName).md"))
    }
    func deleteNote(_ note: Note) throws { deletedNotes.append(note) }
    func renameNote(_ note: Note, to newName: String) throws -> Note {
        renamedTo = newName
        var updated = note
        updated.filename = newName
        return updated
    }
}

@MainActor
final class MockNoteIndexer: NoteIndexing {
    var stubbedCount = 0
    private(set) var loadFromDiskCalled = false
    private(set) var indexAllCalledWith: [Note]?
    private(set) var indexNoteCalledWith: [Note] = []
    private(set) var removeNoteCalledWith: [UUID] = []

    func loadFromDisk() async { loadFromDiskCalled = true }
    func indexedCount() async -> Int { stubbedCount }
    func indexAll(_ notes: [Note]) async throws { indexAllCalledWith = notes }
    func indexNote(_ note: Note) async throws { indexNoteCalledWith.append(note) }
    func removeNote(id: UUID) async { removeNoteCalledWith.append(id) }
    func search(query: String, limit: Int) async throws -> [UUID] { [] }
    func searchRanked(query: String, limit: Int) async throws -> [(id: UUID, score: Float)] { [] }
}

// MARK: - Shared fixture

private func makeNote(
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

// MARK: - In-memory behaviour

@Suite("NoteStore – in-memory")
@MainActor
struct NoteStoreTests {
    let store: NoteStore
    let fs: MockFileService
    let idx: MockNoteIndexer

    init() {
        fs = MockFileService()
        idx = MockNoteIndexer()
        store = NoteStore(fileService: fs, indexer: idx)
    }

    // MARK: selectedNote

    @Test func selectedNoteReturnsMatchingNote() {
        let note = makeNote()
        store.notes = [note]
        store.selectedNoteID = note.id
        #expect(store.selectedNote?.id == note.id)
    }

    @Test func selectedNoteReturnsNilWhenIDUnknown() {
        store.notes = [makeNote()]
        store.selectedNoteID = UUID()
        #expect(store.selectedNote == nil)
    }

    @Test func selectedNoteReturnsNilWhenListEmpty() {
        store.selectedNoteID = UUID()
        #expect(store.selectedNote == nil)
    }

    // MARK: allTags

    @Test func allTagsReturnsSortedUniqueValues() {
        store.notes = [
            makeNote(tags: ["swift", "macOS"]),
            makeNote(tags: ["swift", "swiftUI"]),
        ]
        #expect(store.allTags == ["macOS", "swift", "swiftUI"])
    }

    @Test func allTagsEmptyWhenNoNotes() {
        #expect(store.allTags.isEmpty)
    }

    @Test func allTagsDeduplicatesAcrossNotes() {
        store.notes = [makeNote(tags: ["a"]), makeNote(tags: ["a"]), makeNote(tags: ["a"])]
        #expect(store.allTags == ["a"])
    }

    // MARK: bookmarkedNotes

    @Test func bookmarkedNotesFiltersCorrectly() throws {
        let bm = makeNote(isBookmarked: true)
        store.notes = [bm, makeNote(isBookmarked: false)]
        #expect(store.bookmarkedNotes.count == 1)
        let first = try #require(store.bookmarkedNotes.first)
        #expect(first.id == bm.id)
    }

    @Test func bookmarkedNotesEmptyWhenNoneBookmarked() {
        store.notes = [makeNote(), makeNote()]
        #expect(store.bookmarkedNotes.isEmpty)
    }

    // MARK: updateNote

    @Test func updateNoteUpdatesBodyInMemory() throws {
        var note = makeNote()
        store.notes = [note]
        note.body = "Updated"
        store.updateNote(note)
        let first = try #require(store.notes.first)
        #expect(first.body == "Updated")
    }

    @Test func updateNoteUpdatesTags() throws {
        var note = makeNote(tags: ["old"])
        store.notes = [note]
        note.tags = ["new"]
        store.updateNote(note)
        let first = try #require(store.notes.first)
        #expect(first.tags == ["new"])
    }

    @Test func updateNoteIgnoresUnknownID() throws {
        store.notes = [makeNote(filename: "Real")]
        store.updateNote(makeNote(filename: "Ghost"))
        #expect(store.notes.count == 1)
        let first = try #require(store.notes.first)
        #expect(first.filename == "Real")
    }

    // MARK: deleteNote

    @Test func deleteNoteRemovesFromArray() {
        let note = makeNote()
        store.notes = [note]
        store.deleteNote(note)
        #expect(store.notes.isEmpty)
    }

    @Test func deleteSelectedNoteNilsSelection() {
        let note = makeNote()
        store.notes = [note]
        store.selectedNoteID = note.id
        store.deleteNote(note)
        #expect(store.selectedNoteID == nil)
    }

    @Test func deleteNoteSelectsFirstRemainingWhenSelected() {
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [a, b]
        store.selectedNoteID = b.id
        store.deleteNote(b)
        #expect(store.selectedNoteID == a.id)
    }

    @Test func deleteNoteKeepsSelectionWhenDifferentNoteDeleted() {
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [a, b]
        store.selectedNoteID = a.id
        store.deleteNote(b)
        #expect(store.selectedNoteID == a.id)
    }

    // MARK: toggleBookmark

    @Test func toggleBookmarkFlipsFlagOn() throws {
        let note = makeNote(isBookmarked: false)
        store.notes = [note]
        store.toggleBookmark(for: note.id)
        let first = try #require(store.notes.first)
        #expect(first.isBookmarked == true)
    }

    @Test func toggleBookmarkFlipsFlagOff() throws {
        let note = makeNote(isBookmarked: true)
        store.notes = [note]
        store.toggleBookmark(for: note.id)
        let first = try #require(store.notes.first)
        #expect(first.isBookmarked == false)
    }

    @Test func toggleBookmarkRoundTrip() throws {
        let note = makeNote(isBookmarked: false)
        store.notes = [note]
        store.toggleBookmark(for: note.id)
        store.toggleBookmark(for: note.id)
        let first = try #require(store.notes.first)
        #expect(first.isBookmarked == false)
    }
}

// MARK: - File service wiring

@Suite("NoteStore – file service")
@MainActor
struct NoteStoreFileServiceTests {
    let store: NoteStore
    let fs: MockFileService
    let idx: MockNoteIndexer

    init() {
        fs = MockFileService()
        idx = MockNoteIndexer()
        store = NoteStore(fileService: fs, indexer: idx)
    }

    @Test func loadPopulatesNotesFromFileService() async {
        fs.stubbedNotes = [makeNote(filename: "Alpha"), makeNote(filename: "Beta")]
        await store.load()
        #expect(store.notes.count == 2)
    }

    @Test func createNoteCallsFileService() async {
        await store.createNote()
        #expect(fs.createdBaseName == "New Note")
    }

    @Test func createNoteAddsNoteToArray() async {
        await store.createNote()
        #expect(store.notes.count == 1)
    }

    @Test func createNoteSetsSelection() async throws {
        await store.createNote()
        let first = try #require(store.notes.first)
        #expect(store.selectedNoteID == first.id)
    }

    @Test func updateNoteCallsSaveOnFileService() async throws {
        var note = makeNote()
        store.notes = [note]
        note.body = "Changed"
        store.updateNote(note)
        await Task.yield()
        let saved = try #require(fs.savedNotes.first)
        #expect(saved.body == "Changed")
    }

    @Test func deleteNoteCallsDeleteOnFileService() async throws {
        let note = makeNote()
        store.notes = [note]
        store.deleteNote(note)
        await Task.yield()
        let deleted = try #require(fs.deletedNotes.first)
        #expect(deleted.id == note.id)
    }

    @Test func renameNoteCallsRenameOnFileService() async {
        let note = makeNote(filename: "Old")
        store.notes = [note]
        store.renameNote(note, to: "New")
        await Task.yield()
        #expect(fs.renamedTo == "New")
    }

    @Test func renameNoteUpdatesFilenameInMemory() async throws {
        let note = makeNote(filename: "Old")
        store.notes = [note]
        store.renameNote(note, to: "New")
        await Task.yield()
        let first = try #require(store.notes.first)
        #expect(first.filename == "New")
    }
}

// MARK: - Indexer wiring

@Suite("NoteStore – indexer wiring")
@MainActor
struct NoteStoreIndexerTests {
    let store: NoteStore
    let fs: MockFileService
    let idx: MockNoteIndexer

    init() {
        fs = MockFileService()
        idx = MockNoteIndexer()
        store = NoteStore(fileService: fs, indexer: idx)
    }

    @Test func loadCallsLoadFromDiskOnIndexer() async {
        await store.load()
        #expect(idx.loadFromDiskCalled)
    }

    @Test func loadCallsIndexAllWhenIndexIsEmpty() async {
        fs.stubbedNotes = [makeNote(filename: "A")]
        idx.stubbedCount = 0
        await store.load()
        await Task.yield()
        #expect(idx.indexAllCalledWith != nil)
    }

    @Test func loadSkipsIndexAllWhenIndexIsFullyCovered() async {
        let notes = [makeNote(filename: "A"), makeNote(filename: "B")]
        fs.stubbedNotes = notes
        idx.stubbedCount = 2
        await store.load()
        await Task.yield()
        #expect(idx.indexAllCalledWith == nil)
    }

    @Test func loadReindexesWhenIndexIsPartial() async {
        fs.stubbedNotes = [makeNote(filename: "A"), makeNote(filename: "B"), makeNote(filename: "C")]
        idx.stubbedCount = 1
        await store.load()
        await Task.yield()
        #expect(idx.indexAllCalledWith != nil)
    }

    @Test func createNoteCallsIndexNote() async {
        await store.createNote()
        #expect(idx.indexNoteCalledWith.count == 1)
    }

    @Test func updateNoteCallsIndexNote() async throws {
        var note = makeNote()
        store.notes = [note]
        note.body = "Updated"
        store.updateNote(note)
        await Task.yield()
        let indexed = try #require(idx.indexNoteCalledWith.first)
        #expect(indexed.id == note.id)
    }

    @Test func updateNotePassesUpdatedContent() async throws {
        var note = makeNote()
        store.notes = [note]
        note.body = "New body"
        store.updateNote(note)
        await Task.yield()
        let indexed = try #require(idx.indexNoteCalledWith.first)
        #expect(indexed.body == "New body")
    }

    @Test func updateNoteIgnoresUnknownIDDoesNotIndex() async {
        store.notes = [makeNote(filename: "Real")]
        store.updateNote(makeNote(filename: "Ghost"))
        await Task.yield()
        #expect(idx.indexNoteCalledWith.isEmpty)
    }

    @Test func deleteNoteCallsRemoveNote() async throws {
        let note = makeNote()
        store.notes = [note]
        store.deleteNote(note)
        await Task.yield()
        let removedID = try #require(idx.removeNoteCalledWith.first)
        #expect(removedID == note.id)
    }

    @Test func renameNoteCallsIndexNoteWithNewName() async throws {
        let note = makeNote(filename: "Old")
        store.notes = [note]
        store.renameNote(note, to: "New")
        await Task.yield()
        let indexed = try #require(idx.indexNoteCalledWith.first)
        #expect(indexed.filename == "New")
    }

    @Test func searchDelegatesToIndexer() async throws {
        let results = try await store.search(query: "anything")
        #expect(results.isEmpty)
    }
}
