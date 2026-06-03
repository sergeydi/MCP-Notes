import Foundation
import Testing
@testable import MCPNotesCore
@testable import mcpnotes_mac

// MARK: - Mocks

@MainActor
final class MockFileService: FileServicing {
    var stubbedNotes: [Note] = []
    private(set) var savedNotes: [Note] = []
    private(set) var deletedNotes: [Note] = []
    private(set) var createdBaseName: String?
    private(set) var renamedTo: String?
    var shouldFailRename = false

    func loadAllNotes() throws -> [Note] { stubbedNotes }
    func saveNote(_ note: Note) throws { savedNotes.append(note) }
    func createNote(baseName: String) throws -> Note {
        createdBaseName = baseName
        return Note(id: UUID(), filename: baseName, tags: [], body: "",
                    fileURL: URL(fileURLWithPath: "/tmp/\(baseName).md"))
    }
    func deleteNote(_ note: Note) throws { deletedNotes.append(note) }
    func renameNote(_ note: Note, to newName: String) throws -> Note {
        if shouldFailRename { throw NSError(domain: "test", code: 1) }
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
    private(set) var resetAndClearIndexCalled = false

    func loadFromDisk() async { loadFromDiskCalled = true }
    func indexedCount() async -> Int { stubbedCount }
    func indexAll(_ notes: [Note]) async throws { indexAllCalledWith = notes }
    func indexNote(_ note: Note) async throws { indexNoteCalledWith.append(note) }
    func removeNote(id: UUID) async { removeNoteCalledWith.append(id) }
    func clearHashStore() async {}
    func resetAndClearIndex() async { resetAndClearIndexCalled = true }
    func search(query: String, limit: Int) async throws -> [UUID] { [] }
    func searchRanked(query: String, limit: Int) async throws -> [(id: UUID, score: Float)] { [] }
    func searchBM25Ranked(query: String, limit: Int) async -> [(id: UUID, rank: Int)] { [] }
    func outgoingLinks(from noteID: UUID) async -> [UUID] { [] }
    func incomingLinks(to noteID: UUID) async -> [UUID] { [] }
    func allLinks() async -> [(source: UUID, target: UUID)] { [] }
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

// NoteStore dispatches I/O via unstructured `Task { }`. Tests use `Task.yield()` to let those
// tasks execute before asserting on side effects. This is reliable here because NoteStore,
// MockFileService, and MockNoteIndexer all share @MainActor isolation — no real actor-hop occurs,
// and one yield drains the pending work on the shared executor.
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
        #expect(idx.indexAllCalledWith?.count == fs.stubbedNotes.count)
    }

    @Test func loadAlwaysCallsIndexAllForIncrementalSync() async {
        // indexAll is always called so NoteIndexer can do incremental hash-based sync internally.
        let notes = [makeNote(filename: "A"), makeNote(filename: "B")]
        fs.stubbedNotes = notes
        idx.stubbedCount = 2
        await store.load()
        await Task.yield()
        #expect(idx.indexAllCalledWith != nil)
        #expect(idx.indexAllCalledWith?.count == fs.stubbedNotes.count)
    }

    @Test func loadReindexesWhenIndexIsPartial() async {
        fs.stubbedNotes = [makeNote(filename: "A"), makeNote(filename: "B"), makeNote(filename: "C")]
        idx.stubbedCount = 1
        await store.load()
        await Task.yield()
        #expect(idx.indexAllCalledWith != nil)
        #expect(idx.indexAllCalledWith?.count == fs.stubbedNotes.count)
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

    @Test func updateNotePassesUpdatedTags() async throws {
        var note = makeNote(tags: ["old"])
        store.notes = [note]
        note.tags = ["new"]
        store.updateNote(note)
        await Task.yield()
        let indexed = try #require(idx.indexNoteCalledWith.first)
        #expect(indexed.tags == ["new"])
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

    @Test func reindexAllDoesNothingWhenNotesEmpty() async {
        await store.reindexAll()
        await Task.yield()
        #expect(idx.resetAndClearIndexCalled == false)
        #expect(idx.indexAllCalledWith == nil)
    }

    @Test func reindexAllCallsResetAndClearIndex() async {
        store.notes = [makeNote()]
        await store.reindexAll()
        await Task.yield()
        #expect(idx.resetAndClearIndexCalled)
    }

    @Test func reindexAllCallsIndexAll() async {
        store.notes = [makeNote()]
        await store.reindexAll()
        await Task.yield()
        #expect(idx.indexAllCalledWith != nil)
        #expect(idx.indexAllCalledWith?.count == 1)
    }
}

// MARK: - External change detection

@Suite("NoteStore – external changes")
@MainActor
struct NoteStoreExternalChangesTests {
    let store: NoteStore
    let fs: MockFileService
    let idx: MockNoteIndexer

    init() {
        fs = MockFileService()
        idx = MockNoteIndexer()
        store = NoteStore(fileService: fs, indexer: idx)
    }

    @Test func addsNoteAppearedOnDisk() async {
        let existing = makeNote(filename: "A")
        let added = makeNote(filename: "B")
        store.notes = [existing]
        fs.stubbedNotes = [existing, added]
        await store.reloadExternalChanges()
        #expect(store.notes.count == 2)
        #expect(store.notes.contains { $0.id == added.id })
    }

    @Test func addsNoteCallsIndexNote() async {
        let added = makeNote(filename: "B")
        store.notes = []
        fs.stubbedNotes = [added]
        await store.reloadExternalChanges()
        #expect(idx.indexNoteCalledWith.contains { $0.id == added.id })
    }

    @Test func removesNoteDeletedFromDisk() async {
        let kept = makeNote(filename: "A")
        let removed = makeNote(filename: "B")
        store.notes = [kept, removed]
        fs.stubbedNotes = [kept]
        await store.reloadExternalChanges()
        #expect(store.notes.count == 1)
        #expect(store.notes.contains { $0.id == removed.id } == false)
    }

    @Test func removesNoteCallsRemoveNoteOnIndexer() async {
        let kept = makeNote(filename: "A")
        let removed = makeNote(filename: "B")
        store.notes = [kept, removed]
        fs.stubbedNotes = [kept]
        await store.reloadExternalChanges()
        #expect(idx.removeNoteCalledWith.contains(removed.id))
    }

    @Test func updatesChangedNoteBody() async throws {
        let note = makeNote(filename: "A")
        store.notes = [note]
        var updated = note
        updated.body = "new body"
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let stored = try #require(store.notes.first { $0.id == note.id })
        #expect(stored.body == "new body")
    }

    @Test func updatesChangedNoteCallsIndexNoteWithNewContent() async throws {
        let note = makeNote(filename: "A")
        store.notes = [note]
        var updated = note
        updated.body = "new body"
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let indexed = try #require(idx.indexNoteCalledWith.first { $0.id == note.id })
        #expect(indexed.body == "new body")
    }

    @Test func updatesChangedNoteTags() async throws {
        let note = makeNote(filename: "A", tags: ["old"])
        store.notes = [note]
        var updated = note
        updated.tags = ["new"]
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let stored = try #require(store.notes.first { $0.id == note.id })
        #expect(stored.tags == ["new"])
    }

    @Test func noOpWhenNothingChanged() async {
        let note = makeNote(filename: "A")
        store.notes = [note]
        fs.stubbedNotes = [note]
        await store.reloadExternalChanges()
        #expect(idx.indexNoteCalledWith.isEmpty)
        #expect(idx.removeNoteCalledWith.isEmpty)
    }

    @Test func updatesChangedNoteTagsCallsIndexNoteWithNewTags() async throws {
        let note = makeNote(filename: "A", tags: ["old"])
        store.notes = [note]
        var updated = note
        updated.tags = ["new"]
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let indexed = try #require(idx.indexNoteCalledWith.first { $0.id == note.id })
        #expect(indexed.tags == ["new"])
    }

    @Test func updatesChangedNoteFilename() async throws {
        let note = makeNote(filename: "OldName")
        store.notes = [note]
        var updated = note
        updated.filename = "NewName"
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let stored = try #require(store.notes.first { $0.id == note.id })
        #expect(stored.filename == "NewName")
    }

    @Test func sortsByFilenameAfterReload() async {
        let a = makeNote(filename: "A")
        let c = makeNote(filename: "C")
        let b = makeNote(filename: "B")
        store.notes = [a, c]
        fs.stubbedNotes = [a, c, b]
        await store.reloadExternalChanges()
        #expect(store.notes.map(\.filename) == ["A", "B", "C"])
    }
}

// MARK: - Tag grouping (byTag sidebar mode)

@Suite("NoteStore – tag grouping")
@MainActor
struct NoteStoreTagGroupingTests {
    let store: NoteStore

    init() {
        store = NoteStore(fileService: MockFileService(), indexer: MockNoteIndexer())
    }

    @Test func notesFilteredByTagMatchExpected() {
        let match = makeNote(tags: ["swift"])
        let other = makeNote(tags: ["python"])
        store.notes = [match, other]
        let result = store.notes.filter { $0.tags.contains("swift") }
        #expect(result.count == 1)
        #expect(result.first?.id == match.id)
    }

    @Test func noteWithMultipleTagsAppearsUnderEachTag() {
        let note = makeNote(tags: ["swift", "macOS"])
        store.notes = [note]
        #expect(store.notes.filter { $0.tags.contains("swift") }.count == 1)
        #expect(store.notes.filter { $0.tags.contains("macOS") }.count == 1)
    }

    @Test func untaggedNoteDoesNotAppearInAnyTagGroup() {
        let untagged = makeNote(tags: [])
        store.notes = [untagged]
        for tag in store.allTags {
            #expect(store.notes.filter { $0.tags.contains(tag) }.isEmpty)
        }
    }

    @Test func allTagsDrivesTagGroupsCorrectly() {
        store.notes = [
            makeNote(tags: ["swift", "macOS"]),
            makeNote(tags: ["swift"]),
            makeNote(tags: []),
        ]
        #expect(store.allTags == ["macOS", "swift"])
        #expect(store.notes.filter { $0.tags.contains("swift") }.count == 2)
        #expect(store.notes.filter { $0.tags.contains("macOS") }.count == 1)
        #expect(store.notes.filter { $0.tags.isEmpty }.count == 1)
    }
}

// MARK: - Rename wikilink cascade

@Suite("NoteStore – rename wikilink cascade")
@MainActor
struct NoteStoreRenameWikilinkTests {
    let store: NoteStore
    let fs: MockFileService
    let idx: MockNoteIndexer

    init() {
        fs = MockFileService()
        idx = MockNoteIndexer()
        store = NoteStore(fileService: fs, indexer: idx)
    }

    @Test func updatesWikilinkInOtherNote() async {
        var renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "See [[Old]] for details"
        store.notes = [renamed, other]
        store.renameNote(renamed, to: "New")
        await Task.yield()
        let updatedOther = store.notes.first { $0.id == other.id }
        #expect(updatedOther?.body == "See [[New]] for details")
    }

    @Test func updatesWikilinkCaseInsensitive() async {
        var renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "See [[old]] for details"
        store.notes = [renamed, other]
        store.renameNote(renamed, to: "New")
        await Task.yield()
        let updatedOther = store.notes.first { $0.id == other.id }
        #expect(updatedOther?.body == "See [[New]] for details")
    }

    @Test func doesNotModifyNoteWithoutMatchingWikilink() async {
        var renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "No links here"
        store.notes = [renamed, other]
        store.renameNote(renamed, to: "New")
        await Task.yield()
        #expect(fs.savedNotes.filter { $0.id == other.id }.isEmpty)
    }

    @Test func callsOnCompleteWithUpdatedFilenames() async {
        var renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "[[Old]]"
        store.notes = [renamed, other]
        var result: [String]?
        store.renameNote(renamed, to: "New") { result = $0 }
        await Task.yield()
        #expect(result == ["Other"])
    }

    @Test func callsOnCompleteWithEmptyArrayWhenNoWikilinks() async {
        let renamed = makeNote(filename: "Old")
        let other = makeNote(filename: "Other")
        store.notes = [renamed, other]
        var result: [String]?
        store.renameNote(renamed, to: "New") { result = $0 }
        await Task.yield()
        #expect(result == [])
    }

    @Test func callsOnCompleteWithEmptyArrayWhenFileServiceFails() async {
        fs.shouldFailRename = true
        let renamed = makeNote(filename: "Old")
        store.notes = [renamed]
        var result: [String]?
        store.renameNote(renamed, to: "New") { result = $0 }
        await Task.yield()
        #expect(result == [])
    }

    @Test func saveNoteCalledForEachUpdatedNote() async {
        var renamed = makeNote(filename: "Old")
        var a = makeNote(filename: "A")
        var b = makeNote(filename: "B")
        a.body = "[[Old]]"
        b.body = "[[Old]] and [[Old]] again"
        store.notes = [renamed, a, b]
        store.renameNote(renamed, to: "New")
        await Task.yield()
        let savedIDs = Set(fs.savedNotes.map(\.id))
        #expect(savedIDs.contains(a.id))
        #expect(savedIDs.contains(b.id))
    }

    @Test func indexNoteCalledForRenamedNoteAndEachUpdatedNote() async {
        var renamed = makeNote(filename: "Old")
        var a = makeNote(filename: "A")
        var b = makeNote(filename: "B")
        a.body = "[[Old]]"
        b.body = "[[Old]] and more"
        store.notes = [renamed, a, b]
        store.renameNote(renamed, to: "New")
        // Two yields: first runs the outer renameNote Task (which spawns inner Tasks),
        // second runs the inner indexNote Tasks.
        await Task.yield()
        await Task.yield()
        let indexedIDs = Set(idx.indexNoteCalledWith.map(\.id))
        #expect(indexedIDs.contains(renamed.id))
        #expect(indexedIDs.contains(a.id))
        #expect(indexedIDs.contains(b.id))
    }
}
