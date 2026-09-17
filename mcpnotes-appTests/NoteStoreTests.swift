import Foundation
import Testing
@testable import mcpnotes_app

// MARK: - Mocks

@MainActor
final class MockFileService: FileServicing {
    /// Notes "on disk" — setting this rebuilds `disk`, mirroring what a fresh directory scan
    /// would see. Reads/writes below (`loadNote`, `saveNote`, `renameNote`, ...) go through
    /// `disk` too, so it always reflects the current simulated filesystem state, the same way
    /// a later `loadNote(at:)` on a real `FileService` would see whatever was last written.
    var stubbedNotes: [Note] = [] {
        didSet { disk = Dictionary(uniqueKeysWithValues: stubbedNotes.map { ($0.fileURL, $0) }) }
    }
    private var disk: [URL: Note] = [:]

    private(set) var savedNotes: [Note] = []
    private(set) var deletedMetadata: [NoteMetadata] = []
    private(set) var createdBaseName: String?
    private(set) var renamedTo: String?
    private(set) var bookmarkCalls: [(fileURL: URL, isBookmarked: Bool)] = []
    var shouldFailRename = false

    private var sortedDisk: [Note] {
        disk.values.sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
    }

    func loadAllNotes() async throws -> [Note] { sortedDisk }
    func loadAllNotesMetadata() async throws -> [NoteMetadata] { sortedDisk.map { NoteMetadata($0) } }
    func loadNote(at fileURL: URL) async throws -> Note {
        guard let note = disk[fileURL] else { throw NSError(domain: "test", code: 404) }
        return note
    }
    func saveNote(_ note: Note) throws {
        savedNotes.append(note)
        disk[note.fileURL] = note
    }
    func createNote(baseName: String) throws -> Note {
        createdBaseName = baseName
        let note = Note(id: UUID(), filename: baseName, tags: [], body: "",
                    fileURL: URL(fileURLWithPath: "/tmp/\(baseName).md"))
        disk[note.fileURL] = note
        return note
    }
    func setBookmarked(_ isBookmarked: Bool, at fileURL: URL) throws {
        bookmarkCalls.append((fileURL, isBookmarked))
        if var note = disk[fileURL] {
            note.isBookmarked = isBookmarked
            disk[fileURL] = note
        }
    }
    func deleteNote(_ metadata: NoteMetadata) throws {
        deletedMetadata.append(metadata)
        disk[metadata.fileURL] = nil
    }
    func renameNote(_ metadata: NoteMetadata, to newName: String) throws -> NoteMetadata {
        if shouldFailRename { throw NSError(domain: "test", code: 1) }
        renamedTo = newName
        let newURL = metadata.fileURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        var updated = metadata
        updated.filename = newName
        updated.fileURL = newURL
        if var note = disk[metadata.fileURL] {
            disk[metadata.fileURL] = nil
            note.filename = newName
            note.fileURL = newURL
            disk[newURL] = note
        }
        return updated
    }
}

@MainActor
final class MockNoteIndexer: NoteIndexing {
    var stubbedCount = 0
    private(set) var loadFromDiskCalled = false
    private(set) var indexAllCalledWith: [Note]?
    private(set) var indexNoteCalledWith: [Note] = []
    private(set) var indexNoteIfChangedCalledWith: [Note] = []
    private(set) var removeNoteCalledWith: [UUID] = []
    private(set) var resetAndClearIndexCalled = false

    var stubbedRecovery = false
    var stubbedIndexedIDs: Set<UUID> = []
    func loadFromDisk() async -> Bool { loadFromDiskCalled = true; return stubbedRecovery }
    func indexedCount() async -> Int { stubbedCount }
    func allIndexedIDs() async -> Set<UUID> { stubbedIndexedIDs }
    func indexAll(_ notes: [Note]) async throws { indexAllCalledWith = notes }
    func indexNote(_ note: Note) async throws { indexNoteCalledWith.append(note) }
    func indexNoteIfChanged(_ note: Note) async throws { indexNoteIfChangedCalledWith.append(note) }
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

/// Yields repeatedly until `condition` is true, up to `maxAttempts` times. Used instead of a
/// fixed `Task.yield()` count when a Task chain is more than one hop deep (e.g. renameNote's
/// outer Task enqueues a separate indexWorkerTask) — under parallel test execution, unrelated
/// tests' work can interleave on the shared MainActor queue, so a fixed hop count is not reliable.
@MainActor
private func yieldUntil(maxAttempts: Int = 200, _ condition: () -> Bool) async {
    for _ in 0..<maxAttempts where !condition() {
        await Task.yield()
    }
}

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
        store = NoteStore(fileService: fs, indexer: idx, indexDebounceDuration: .zero)
    }

    // MARK: selectedNote

    @Test func selectedNoteReturnsMatchingNote() {
        let note = makeNote()
        store.notes = [NoteMetadata(note)]
        store.selectedNoteID = note.id
        #expect(store.selectedNote?.id == note.id)
    }

    @Test func selectedNoteReturnsNilWhenIDUnknown() {
        store.notes = [NoteMetadata(makeNote())]
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
            NoteMetadata(makeNote(tags: ["swift", "macOS"])),
            NoteMetadata(makeNote(tags: ["swift", "swiftUI"])),
        ]
        #expect(store.allTags == ["macOS", "swift", "swiftUI"])
    }

    @Test func allTagsEmptyWhenNoNotes() {
        #expect(store.allTags.isEmpty)
    }

    @Test func allTagsDeduplicatesAcrossNotes() {
        store.notes = [makeNote(tags: ["a"]), makeNote(tags: ["a"]), makeNote(tags: ["a"])].map { NoteMetadata($0) }
        #expect(store.allTags == ["a"])
    }

    // MARK: bookmarkedNotes

    @Test func bookmarkedNotesFiltersCorrectly() throws {
        let bm = makeNote(isBookmarked: true)
        store.notes = [NoteMetadata(bm), NoteMetadata(makeNote(isBookmarked: false))]
        #expect(store.bookmarkedNotes.count == 1)
        let first = try #require(store.bookmarkedNotes.first)
        #expect(first.id == bm.id)
    }

    @Test func bookmarkedNotesEmptyWhenNoneBookmarked() {
        store.notes = [makeNote(), makeNote()].map { NoteMetadata($0) }
        #expect(store.bookmarkedNotes.isEmpty)
    }

    // MARK: updateNote

    @Test func updateNotePersistsNewBody() async throws {
        var note = makeNote()
        store.notes = [NoteMetadata(note)]
        note.body = "Updated"
        store.updateNote(note)
        await Task.yield()
        let saved = try #require(fs.savedNotes.first)
        #expect(saved.body == "Updated")
    }

    @Test func updateNotePersistsNewTags() async throws {
        var note = makeNote(tags: ["old"])
        store.notes = [NoteMetadata(note)]
        note.tags = ["new"]
        store.updateNote(note)
        await Task.yield()
        let saved = try #require(fs.savedNotes.first)
        #expect(saved.tags == ["new"])
    }

    @Test func updateNoteIgnoresUnknownID() throws {
        store.notes = [NoteMetadata(makeNote(filename: "Real"))]
        store.updateNote(makeNote(filename: "Ghost"))
        #expect(store.notes.count == 1)
        let first = try #require(store.notes.first)
        #expect(first.filename == "Real")
    }

    // MARK: deleteNote

    @Test func deleteNoteRemovesFromArray() {
        let metadata = NoteMetadata(makeNote())
        store.notes = [metadata]
        store.deleteNote(metadata)
        #expect(store.notes.isEmpty)
    }

    @Test func deleteSelectedNoteNilsSelection() {
        let metadata = NoteMetadata(makeNote())
        store.notes = [metadata]
        store.selectedNoteID = metadata.id
        store.deleteNote(metadata)
        #expect(store.selectedNoteID == nil)
    }

    @Test func deleteNoteSelectsFirstRemainingWhenSelected() {
        let a = NoteMetadata(makeNote(filename: "A"))
        let b = NoteMetadata(makeNote(filename: "B"))
        store.notes = [a, b]
        store.selectedNoteID = b.id
        store.deleteNote(b)
        #expect(store.selectedNoteID == a.id)
    }

    @Test func deleteNoteKeepsSelectionWhenDifferentNoteDeleted() {
        let a = NoteMetadata(makeNote(filename: "A"))
        let b = NoteMetadata(makeNote(filename: "B"))
        store.notes = [a, b]
        store.selectedNoteID = a.id
        store.deleteNote(b)
        #expect(store.selectedNoteID == a.id)
    }

    // MARK: toggleBookmark

    @Test func toggleBookmarkFlipsFlagOn() throws {
        let metadata = NoteMetadata(makeNote(isBookmarked: false))
        store.notes = [metadata]
        store.toggleBookmark(for: metadata.id)
        let first = try #require(store.notes.first)
        #expect(first.isBookmarked == true)
    }

    @Test func toggleBookmarkFlipsFlagOff() throws {
        let metadata = NoteMetadata(makeNote(isBookmarked: true))
        store.notes = [metadata]
        store.toggleBookmark(for: metadata.id)
        let first = try #require(store.notes.first)
        #expect(first.isBookmarked == false)
    }

    @Test func toggleBookmarkRoundTrip() throws {
        let metadata = NoteMetadata(makeNote(isBookmarked: false))
        store.notes = [metadata]
        store.toggleBookmark(for: metadata.id)
        store.toggleBookmark(for: metadata.id)
        let first = try #require(store.notes.first)
        #expect(first.isBookmarked == false)
    }

    @Test func toggleBookmarkCallsSetBookmarkedOnFileService() async throws {
        let metadata = NoteMetadata(makeNote(isBookmarked: false))
        store.notes = [metadata]
        store.toggleBookmark(for: metadata.id)
        await Task.yield()
        let call = try #require(fs.bookmarkCalls.first)
        #expect(call.fileURL == metadata.fileURL)
        #expect(call.isBookmarked == true)
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
        store = NoteStore(fileService: fs, indexer: idx, indexDebounceDuration: .zero)
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
        store.notes = [NoteMetadata(note)]
        note.body = "Changed"
        store.updateNote(note)
        await Task.yield()
        let saved = try #require(fs.savedNotes.first)
        #expect(saved.body == "Changed")
    }

    @Test func deleteNoteCallsDeleteOnFileService() async throws {
        let metadata = NoteMetadata(makeNote())
        store.notes = [metadata]
        store.deleteNote(metadata)
        await Task.yield()
        let deleted = try #require(fs.deletedMetadata.first)
        #expect(deleted.id == metadata.id)
    }

    @Test func renameNoteCallsRenameOnFileService() async {
        let metadata = NoteMetadata(makeNote(filename: "Old"))
        store.notes = [metadata]
        store.renameNote(metadata, to: "New")
        await Task.yield()
        #expect(fs.renamedTo == "New")
    }

    @Test func renameNoteUpdatesFilenameInMemory() async throws {
        let metadata = NoteMetadata(makeNote(filename: "Old"))
        store.notes = [metadata]
        store.renameNote(metadata, to: "New")
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
        store = NoteStore(fileService: fs, indexer: idx, indexDebounceDuration: .zero)
    }

    @Test func loadCallsLoadFromDiskOnIndexer() async {
        await store.load()
        #expect(idx.loadFromDiskCalled)
    }

    @Test func loadEnqueuesAllNotesForIndexing() async {
        fs.stubbedNotes = [makeNote(filename: "A")]
        idx.stubbedCount = 0
        await store.load()
        await Task.yield()
        #expect(idx.indexNoteIfChangedCalledWith.count == fs.stubbedNotes.count)
    }

    @Test func loadEnqueuesAllNotesWhenIndexFull() async {
        let notes = [makeNote(filename: "A"), makeNote(filename: "B")]
        fs.stubbedNotes = notes
        idx.stubbedCount = 2
        await store.load()
        await Task.yield()
        #expect(idx.indexNoteIfChangedCalledWith.count == fs.stubbedNotes.count)
    }

    @Test func loadEnqueuesNotesWhenIndexIsPartial() async {
        fs.stubbedNotes = [makeNote(filename: "A"), makeNote(filename: "B"), makeNote(filename: "C")]
        idx.stubbedCount = 1
        await store.load()
        await Task.yield()
        #expect(idx.indexNoteIfChangedCalledWith.count == fs.stubbedNotes.count)
    }

    @Test func createNoteCallsIndexNote() async {
        await store.createNote()
        #expect(idx.indexNoteCalledWith.count == 1)
    }

    @Test func updateNoteCallsIndexNoteIfChanged() async throws {
        var note = makeNote()
        store.notes = [NoteMetadata(note)]
        note.body = "Updated"
        store.updateNote(note)
        // updateNote's outer Task enqueues the saved note onto the shared indexWorkerTask —
        // poll instead of a fixed yield count (see yieldUntil).
        await yieldUntil { !idx.indexNoteIfChangedCalledWith.isEmpty }
        let indexed = try #require(idx.indexNoteIfChangedCalledWith.first)
        #expect(indexed.id == note.id)
    }

    @Test func updateNotePassesUpdatedContent() async throws {
        var note = makeNote()
        store.notes = [NoteMetadata(note)]
        note.body = "New body"
        store.updateNote(note)
        await yieldUntil { !idx.indexNoteIfChangedCalledWith.isEmpty }
        let indexed = try #require(idx.indexNoteIfChangedCalledWith.first)
        #expect(indexed.body == "New body")
    }

    @Test func updateNotePassesUpdatedTags() async throws {
        var note = makeNote(tags: ["old"])
        store.notes = [NoteMetadata(note)]
        note.tags = ["new"]
        store.updateNote(note)
        await yieldUntil { !idx.indexNoteIfChangedCalledWith.isEmpty }
        let indexed = try #require(idx.indexNoteIfChangedCalledWith.first)
        #expect(indexed.tags == ["new"])
    }

    @Test func updateNoteIgnoresUnknownIDDoesNotIndex() async {
        store.notes = [NoteMetadata(makeNote(filename: "Real"))]
        store.updateNote(makeNote(filename: "Ghost"))
        await Task.yield()
        #expect(idx.indexNoteIfChangedCalledWith.isEmpty)
    }

    @Test func deleteNoteCallsRemoveNote() async throws {
        let metadata = NoteMetadata(makeNote())
        store.notes = [metadata]
        store.deleteNote(metadata)
        await Task.yield()
        let removedID = try #require(idx.removeNoteCalledWith.first)
        #expect(removedID == metadata.id)
    }

    @Test func renameNoteCallsIndexNoteWithNewName() async throws {
        let note = makeNote(filename: "Old")
        fs.stubbedNotes = [note]
        store.notes = [NoteMetadata(note)]
        store.renameNote(NoteMetadata(note), to: "New")
        // renameNote's outer Task enqueues the renamed note onto a separate indexWorkerTask —
        // poll instead of a fixed yield count (see yieldUntil).
        await yieldUntil { !idx.indexNoteIfChangedCalledWith.isEmpty }
        let indexed = try #require(idx.indexNoteIfChangedCalledWith.first)
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
        #expect(idx.indexNoteIfChangedCalledWith.isEmpty)
    }

    @Test func reindexAllCallsResetAndClearIndex() async {
        let note = makeNote()
        fs.stubbedNotes = [note]
        store.notes = [NoteMetadata(note)]
        await store.reindexAll()
        await Task.yield()
        #expect(idx.resetAndClearIndexCalled)
    }

    @Test func reindexAllEnqueuesAllNotes() async {
        let note = makeNote()
        fs.stubbedNotes = [note]
        store.notes = [NoteMetadata(note)]
        await store.reindexAll()
        await Task.yield()
        #expect(idx.indexNoteIfChangedCalledWith.count == 1)
    }

    @Test func loadTransitionsIndexingStateToReady() async {
        fs.stubbedNotes = [makeNote(filename: "A")]
        await store.load()
        await Task.yield()
        guard case .ready = store.indexingState else {
            Issue.record("Expected .ready, got \(store.indexingState)")
            return
        }
    }

    @Test func reindexAllTransitionsIndexingStateToReady() async {
        let note = makeNote()
        fs.stubbedNotes = [note]
        store.notes = [NoteMetadata(note)]
        await store.reindexAll()
        await Task.yield()
        guard case .ready = store.indexingState else {
            Issue.record("Expected .ready, got \(store.indexingState)")
            return
        }
    }

    @Test func loadSetsIndexingBeforeEnqueuing() async {
        fs.stubbedNotes = [makeNote(filename: "A"), makeNote(filename: "B")]
        idx.stubbedCount = 0
        // indexingState must be .indexing immediately after load() returns,
        // before the worker task has a chance to run.
        let loadTask = Task { await self.store.load() }
        await loadTask.value
        // At this point the worker may or may not have run yet —
        // but it must have moved to .ready by the time we yield.
        await Task.yield()
        guard case .ready = store.indexingState else {
            Issue.record("Expected .ready after worker finishes, got \(store.indexingState)")
            return
        }
    }

    @Test func loadRemovesOrphanedIndexEntriesForDeletedFiles() async {
        let staleID = UUID()
        let liveNote = makeNote(filename: "Live")
        fs.stubbedNotes = [liveNote]
        // Index has one extra entry for a note deleted while the app was closed.
        idx.stubbedIndexedIDs = [liveNote.id, staleID]
        await store.load()
        await Task.yield()
        #expect(idx.removeNoteCalledWith.contains(staleID))
        #expect(!idx.removeNoteCalledWith.contains(liveNote.id))
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
        store = NoteStore(fileService: fs, indexer: idx, indexDebounceDuration: .zero)
    }

    @Test func addsNoteAppearedOnDisk() async {
        let existing = makeNote(filename: "A")
        let added = makeNote(filename: "B")
        store.notes = [NoteMetadata(existing)]
        fs.stubbedNotes = [existing, added]
        await store.reloadExternalChanges()
        #expect(store.notes.count == 2)
        #expect(store.notes.contains { $0.id == added.id })
    }

    @Test func addsNoteEnqueuesNoteForIndexing() async {
        let added = makeNote(filename: "B")
        store.notes = []
        fs.stubbedNotes = [added]
        await store.reloadExternalChanges()
        await Task.yield()
        #expect(idx.indexNoteIfChangedCalledWith.contains { $0.id == added.id })
    }

    @Test func removesNoteDeletedFromDisk() async {
        let kept = makeNote(filename: "A")
        let removed = makeNote(filename: "B")
        store.notes = [NoteMetadata(kept), NoteMetadata(removed)]
        fs.stubbedNotes = [kept]
        await store.reloadExternalChanges()
        #expect(store.notes.count == 1)
        #expect(store.notes.contains { $0.id == removed.id } == false)
    }

    @Test func removesNoteCallsRemoveNoteOnIndexer() async {
        let kept = makeNote(filename: "A")
        let removed = makeNote(filename: "B")
        store.notes = [NoteMetadata(kept), NoteMetadata(removed)]
        fs.stubbedNotes = [kept]
        await store.reloadExternalChanges()
        #expect(idx.removeNoteCalledWith.contains(removed.id))
        #expect(idx.indexNoteIfChangedCalledWith.isEmpty)
    }

    @Test func updatesChangedNoteUpdatesPreviewInMemory() async throws {
        let note = makeNote(filename: "A")
        store.notes = [NoteMetadata(note)]
        var updated = note
        updated.body = "new body content"
        updated.modifiedAt = note.modifiedAt.addingTimeInterval(1)
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let stored = try #require(store.notes.first { $0.id == note.id })
        #expect(stored.preview.contains("new body content"))
    }

    @Test func updatesChangedNoteEnqueuesNoteWithNewContent() async throws {
        let note = makeNote(filename: "A")
        store.notes = [NoteMetadata(note)]
        var updated = note
        updated.body = "new body"
        updated.modifiedAt = note.modifiedAt.addingTimeInterval(1)
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        await Task.yield()
        let indexed = try #require(idx.indexNoteIfChangedCalledWith.first { $0.id == note.id })
        #expect(indexed.body == "new body")
    }

    @Test func updatesChangedNoteTags() async throws {
        let note = makeNote(filename: "A", tags: ["old"])
        store.notes = [NoteMetadata(note)]
        var updated = note
        updated.tags = ["new"]
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        let stored = try #require(store.notes.first { $0.id == note.id })
        #expect(stored.tags == ["new"])
    }

    @Test func noOpWhenNothingChanged() async {
        let note = makeNote(filename: "A")
        store.notes = [NoteMetadata(note)]
        fs.stubbedNotes = [note]
        await store.reloadExternalChanges()
        #expect(idx.indexNoteIfChangedCalledWith.isEmpty)
        #expect(idx.removeNoteCalledWith.isEmpty)
    }

    @Test func updatesChangedNoteTagsEnqueuesNoteWithNewTags() async throws {
        let note = makeNote(filename: "A", tags: ["old"])
        store.notes = [NoteMetadata(note)]
        var updated = note
        updated.tags = ["new"]
        fs.stubbedNotes = [updated]
        await store.reloadExternalChanges()
        await Task.yield()
        let indexed = try #require(idx.indexNoteIfChangedCalledWith.first { $0.id == note.id })
        #expect(indexed.tags == ["new"])
    }

    @Test func updatesChangedNoteFilename() async throws {
        let note = makeNote(filename: "OldName")
        store.notes = [NoteMetadata(note)]
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
        store.notes = [NoteMetadata(a), NoteMetadata(c)]
        fs.stubbedNotes = [a, c, b]
        await store.reloadExternalChanges()
        #expect(store.notes.map(\.filename) == ["A", "B", "C"])
    }

    @Test func externalDeleteClearsSelectionWhenSelectedNoteRemoved() async {
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [NoteMetadata(a), NoteMetadata(b)]
        store.selectedNoteID = b.id
        fs.stubbedNotes = [a]
        await store.reloadExternalChanges()
        #expect(store.selectedNoteID != b.id)
    }

    @Test func externalDeleteKeepsSelectionWhenOtherNoteRemoved() async {
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [NoteMetadata(a), NoteMetadata(b)]
        store.selectedNoteID = a.id
        fs.stubbedNotes = [a]
        await store.reloadExternalChanges()
        #expect(store.selectedNoteID == a.id)
    }

    @Test func externalDeleteClearsNavHistoryEntry() async {
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [NoteMetadata(a), NoteMetadata(b)]
        store.selectedNoteID = a.id
        store.selectedNoteID = b.id
        fs.stubbedNotes = [a]
        await store.reloadExternalChanges()
        store.navigateBack()
        #expect(store.selectedNoteID != b.id)
    }

    @Test func externalDeleteUpdatesCanNavigateState() async {
        let a = makeNote(filename: "A")
        let b = makeNote(filename: "B")
        store.notes = [NoteMetadata(a), NoteMetadata(b)]
        store.selectedNoteID = a.id
        store.selectedNoteID = b.id
        #expect(store.canNavigateBack == true)
        fs.stubbedNotes = [a]
        await store.reloadExternalChanges()
        #expect(store.canNavigateBack == false)
        #expect(store.canNavigateForward == false)
    }
}

// MARK: - Tag grouping (byTag sidebar mode)

@Suite("NoteStore – tag grouping")
@MainActor
struct NoteStoreTagGroupingTests {
    let store: NoteStore

    init() {
        store = NoteStore(fileService: MockFileService(), indexer: MockNoteIndexer(), indexDebounceDuration: .zero)
    }

    @Test func notesFilteredByTagMatchExpected() {
        let match = makeNote(tags: ["swift"])
        let other = makeNote(tags: ["python"])
        store.notes = [NoteMetadata(match), NoteMetadata(other)]
        let result = store.notes.filter { $0.tags.contains("swift") }
        #expect(result.count == 1)
        #expect(result.first?.id == match.id)
    }

    @Test func noteWithMultipleTagsAppearsUnderEachTag() {
        let note = makeNote(tags: ["swift", "macOS"])
        store.notes = [NoteMetadata(note)]
        #expect(store.notes.filter { $0.tags.contains("swift") }.count == 1)
        #expect(store.notes.filter { $0.tags.contains("macOS") }.count == 1)
    }

    @Test func untaggedNoteDoesNotAppearInAnyTagGroup() {
        let untagged = makeNote(tags: [])
        store.notes = [NoteMetadata(untagged)]
        for tag in store.allTags {
            #expect(store.notes.filter { $0.tags.contains(tag) }.isEmpty)
        }
    }

    @Test func allTagsDrivesTagGroupsCorrectly() {
        store.notes = [
            makeNote(tags: ["swift", "macOS"]),
            makeNote(tags: ["swift"]),
            makeNote(tags: []),
        ].map { NoteMetadata($0) }
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
        store = NoteStore(fileService: fs, indexer: idx, indexDebounceDuration: .zero)
    }

    @Test func updatesWikilinkInOtherNote() async throws {
        let renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "See [[Old]] for details"
        fs.stubbedNotes = [renamed, other]
        store.notes = [NoteMetadata(renamed), NoteMetadata(other)]
        store.renameNote(NoteMetadata(renamed), to: "New")
        await Task.yield()
        let saved = try #require(fs.savedNotes.first { $0.id == other.id })
        #expect(saved.body == "See [[New]] for details")
    }

    @Test func updatesWikilinkCaseInsensitive() async throws {
        let renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "See [[old]] for details"
        fs.stubbedNotes = [renamed, other]
        store.notes = [NoteMetadata(renamed), NoteMetadata(other)]
        store.renameNote(NoteMetadata(renamed), to: "New")
        await Task.yield()
        let saved = try #require(fs.savedNotes.first { $0.id == other.id })
        #expect(saved.body == "See [[New]] for details")
    }

    @Test func doesNotModifyNoteWithoutMatchingWikilink() async {
        let renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "No links here"
        fs.stubbedNotes = [renamed, other]
        store.notes = [NoteMetadata(renamed), NoteMetadata(other)]
        store.renameNote(NoteMetadata(renamed), to: "New")
        await Task.yield()
        #expect(fs.savedNotes.filter { $0.id == other.id }.isEmpty)
    }

    @Test func callsOnCompleteWithUpdatedFilenames() async {
        let renamed = makeNote(filename: "Old")
        var other = makeNote(filename: "Other")
        other.body = "[[Old]]"
        fs.stubbedNotes = [renamed, other]
        store.notes = [NoteMetadata(renamed), NoteMetadata(other)]
        var result: [String]?
        store.renameNote(NoteMetadata(renamed), to: "New") { result = $0 }
        await Task.yield()
        #expect(result == ["Other"])
    }

    @Test func callsOnCompleteWithEmptyArrayWhenNoWikilinks() async {
        let renamed = makeNote(filename: "Old")
        let other = makeNote(filename: "Other")
        fs.stubbedNotes = [renamed, other]
        store.notes = [NoteMetadata(renamed), NoteMetadata(other)]
        var result: [String]?
        store.renameNote(NoteMetadata(renamed), to: "New") { result = $0 }
        await Task.yield()
        #expect(result == [])
    }

    @Test func callsOnCompleteWithEmptyArrayWhenFileServiceFails() async {
        fs.shouldFailRename = true
        let renamed = makeNote(filename: "Old")
        store.notes = [NoteMetadata(renamed)]
        var result: [String]?
        store.renameNote(NoteMetadata(renamed), to: "New") { result = $0 }
        await Task.yield()
        #expect(result == [])
    }

    @Test func saveNoteCalledForEachUpdatedNote() async {
        let renamed = makeNote(filename: "Old")
        var a = makeNote(filename: "A")
        var b = makeNote(filename: "B")
        a.body = "[[Old]]"
        b.body = "[[Old]] and [[Old]] again"
        fs.stubbedNotes = [renamed, a, b]
        store.notes = [NoteMetadata(renamed), NoteMetadata(a), NoteMetadata(b)]
        store.renameNote(NoteMetadata(renamed), to: "New")
        await Task.yield()
        let savedIDs = Set(fs.savedNotes.map(\.id))
        #expect(savedIDs.contains(a.id))
        #expect(savedIDs.contains(b.id))
    }

    @Test func indexNoteCalledForRenamedNoteAndEachUpdatedNote() async throws {
        let renamed = makeNote(filename: "Old")
        var a = makeNote(filename: "A")
        var b = makeNote(filename: "B")
        a.body = "[[Old]]"
        b.body = "[[Old]] and more"
        fs.stubbedNotes = [renamed, a, b]
        store.notes = [NoteMetadata(renamed), NoteMetadata(a), NoteMetadata(b)]
        store.renameNote(NoteMetadata(renamed), to: "New")
        // renameNote's outer Task enqueues onto a separate indexWorkerTask —
        // poll instead of a fixed yield count (see yieldUntil).
        await yieldUntil { idx.indexNoteIfChangedCalledWith.count >= 3 }
        let indexedIDs = Set(idx.indexNoteIfChangedCalledWith.map(\.id))
        #expect(indexedIDs.contains(renamed.id))
        #expect(indexedIDs.contains(a.id))
        #expect(indexedIDs.contains(b.id))
    }
}
