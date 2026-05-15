import Foundation
import Testing
@testable import mcpnotes_mac

/// Integration tests — download multilingual-e5-small (~115 MB) on first run.
/// Model is cached in ~/Library/Caches/huggingface after that.
// .serialized has no effect on non-parameterized tests; actual serialization comes from @MainActor.
@Suite("NoteIndexer – integration", .timeLimit(.minutes(5)))
@MainActor
struct NoteIndexerTests {

    func makeNote(filename: String, body: String, tags: [String] = []) -> Note {
        Note(
            id: UUID(),
            filename: filename,
            tags: tags,
            body: body,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"),
            isBookmarked: false
        )
    }

    // MARK: - Semantic search

    @Test("search returns the most relevant note first")
    func searchReturnsMostRelevantNoteFirst() async throws {
        let indexer = NoteIndexer()

        let swift = makeNote(
            filename: "Swift Programming",
            body: "Swift is a powerful compiled language for iOS and macOS development. It features strong typing and modern concurrency."
        )
        let pasta = makeNote(
            filename: "Pasta Recipe",
            body: "Boil salted water. Cook spaghetti for 10 minutes. Add homemade tomato sauce and parmesan."
        )
        let garden = makeNote(
            filename: "Gardening Tips",
            body: "Water plants every morning. Use compost as fertilizer in spring. Prune roses in autumn."
        )

        try await indexer.indexAll([swift, pasta, garden])

        let results = try await indexer.search(query: "programming language Xcode", limit: 3)

        #expect(results.first == swift.id, "Swift note should rank first for a programming query")
    }

    @Test("search ranks cooking note above others for food query")
    func searchRanksCookingNoteForFoodQuery() async throws {
        let indexer = NoteIndexer()

        let swift = makeNote(
            filename: "Swift",
            body: "Protocols, generics, and value types are core Swift concepts."
        )
        let recipe = makeNote(
            filename: "Chocolate Cake",
            body: "Mix flour, cocoa powder, eggs and butter. Bake at 180°C for 35 minutes."
        )

        try await indexer.indexAll([swift, recipe])

        let results = try await indexer.search(query: "baking ingredients oven", limit: 2)

        #expect(results.first == recipe.id, "Recipe note should rank first for a cooking query")
    }

    // MARK: - CRUD

    @Test("removeNote excludes note from subsequent searches")
    func removeNoteExcludesFromResults() async throws {
        let indexer = NoteIndexer()

        let ai = makeNote(
            filename: "Machine Learning",
            body: "Neural networks and gradient descent are foundations of modern AI."
        )
        let cake = makeNote(
            filename: "Baking",
            body: "A good sponge cake needs properly beaten eggs and sifted flour."
        )

        try await indexer.indexAll([ai, cake])
        await indexer.removeNote(id: ai.id)

        let results = try await indexer.search(query: "neural network deep learning", limit: 2)

        #expect(results.contains(ai.id) == false, "Removed note must not appear in results after removeNote")
    }

    @Test("tags boost ranking for matching queries")
    func tagsBoostRanking() async throws {
        let indexer = NoteIndexer()

        let tagged = makeNote(
            filename: "Notes on concurrency",
            body: "Some general thoughts.",
            tags: ["swift", "async", "actor"]
        )
        let untagged = makeNote(
            filename: "Diary entry",
            body: "Today was a good day.",
            tags: []
        )

        try await indexer.indexAll([tagged, untagged])

        let results = try await indexer.search(query: "Swift concurrency async", limit: 2)
        #expect(results.first == tagged.id, "Tagged note should rank first")
    }

    @Test("cross-lingual: Russian query finds English note")
    func crossLingualRussianQueryFindsEnglishNote() async throws {
        let indexer = NoteIndexer()

        let swift = makeNote(
            filename: "Swift Programming",
            body: "Swift is a compiled language for iOS and macOS. It uses strong typing and modern concurrency with async/await."
        )
        let recipe = makeNote(
            filename: "Pasta Recipe",
            body: "Boil water, cook spaghetti for 10 minutes, add tomato sauce."
        )

        try await indexer.indexAll([swift, recipe])

        let results = try await indexer.search(query: "язык программирования разработка приложений", limit: 2)
        #expect(results.first == swift.id, "Russian query should find English programming note")
    }

    @Test("cross-lingual: English query finds Russian note")
    func crossLingualEnglishQueryFindsRussianNote() async throws {
        let indexer = NoteIndexer()

        let cooking = makeNote(
            filename: "Готовим пасту",
            body: "Вскипятить воду, добавить соль. Варить спагетти 10 минут. Добавить томатный соус и пармезан."
        )
        let finance = makeNote(
            filename: "Личные финансы",
            body: "Ежемесячный бюджет: аренда, продукты, транспорт. Откладывать 20% дохода."
        )

        try await indexer.indexAll([cooking, finance])

        let results = try await indexer.search(query: "cooking recipe ingredients pasta", limit: 2)
        #expect(results.first == cooking.id, "English query should find Russian cooking note")
    }

    @Test("limit parameter caps result count")
    func limitCapsResultCount() async throws {
        let indexer = NoteIndexer()

        let notes = (1...5).map {
            makeNote(filename: "Note \($0)", body: "Swift programming iOS macOS development note number \($0).")
        }
        try await indexer.indexAll(notes)

        let results = try await indexer.search(query: "Swift development", limit: 3)
        #expect(results.count <= 3)
    }

    @Test("search on empty index returns empty array")
    func searchOnEmptyIndexReturnsEmpty() async throws {
        let indexer = NoteIndexer()
        let results = try await indexer.search(query: "anything", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("indexAll with empty array does not crash")
    func indexAllEmptyArrayIsNoop() async throws {
        let indexer = NoteIndexer()
        try await indexer.indexAll([])
        let results = try await indexer.search(query: "test", limit: 5)
        #expect(results.isEmpty)
    }

    // MARK: - Re-indexing

    @Test("re-indexing a note updates its searchable content")
    func reindexUpdatesContent() async throws {
        let indexer = NoteIndexer()

        let id = UUID()
        let original = Note(
            id: id,
            filename: "My Note",
            tags: [],
            body: "Boil water, cook spaghetti, add tomato sauce.",
            fileURL: URL(fileURLWithPath: "/tmp/my-note.md"),
            isBookmarked: false
        )
        let updated = Note(
            id: id,
            filename: "My Note",
            tags: [],
            body: "Swift actors and async/await are core concurrency primitives.",
            fileURL: URL(fileURLWithPath: "/tmp/my-note.md"),
            isBookmarked: false
        )
        let other = makeNote(
            filename: "Gardening",
            body: "Water plants every morning and use compost as fertilizer."
        )

        try await indexer.indexAll([original, other])
        try await indexer.indexNote(updated)

        let results = try await indexer.search(query: "Swift concurrency programming", limit: 2)
        #expect(results.first == id, "Re-indexed note should rank first after content update")
    }

    // MARK: - Chunking

    @Test("chunking: note with relevant paragraph ranks above unrelated note")
    func chunkingBoostsRelevantParagraph() async throws {
        let indexer = NoteIndexer()

        // Two paragraphs: one about hiking gear, one listing medicine names.
        let medical = makeNote(
            filename: "Аптечка для Хайкинга",
            body: "Снаряжение для похода: палатки, спальники, треккинговые палки.\n\nЛекарства: Ибупрофен, Цетиризин, Лоперамид — основные таблетки в аптечке."
        )
        let todo = makeNote(
            filename: "App ToDo",
            body: "Задачи для приложения: добавить автодополнение тегов, увеличить размер шрифта."
        )

        try await indexer.indexAll([medical, todo])

        let results = try await indexer.search(query: "таблетки лекарства", limit: 2)
        #expect(results.first == medical.id, "Note with medicine paragraph should rank first")
    }

    @Test("removeNote removes all chunk vectors from the index")
    func removeNoteRemovesAllChunkVectors() async throws {
        let indexer = NoteIndexer()

        // Note with multiple paragraphs → multiple chunk vectors indexed.
        let note = makeNote(
            filename: "Multi-paragraph Note",
            body: "First paragraph about Swift programming.\n\nSecond paragraph about actor isolation.\n\nThird paragraph about structured concurrency."
        )
        let other = makeNote(filename: "Other", body: "Cooking recipes and fresh ingredients.")

        try await indexer.indexAll([note, other])
        await indexer.removeNote(id: note.id)

        let results = try await indexer.search(query: "Swift concurrency actors", limit: 5)
        #expect(results.contains(note.id) == false, "All chunks of removed note must be gone from index")
    }

    @Test("re-indexing a multi-paragraph note replaces all old chunks")
    func reindexReplacesAllChunks() async throws {
        let indexer = NoteIndexer()

        let id = UUID()
        let original = Note(
            id: id,
            filename: "My Note",
            tags: [],
            body: "First cooking paragraph.\n\nSecond cooking paragraph with pasta recipes.",
            fileURL: URL(fileURLWithPath: "/tmp/my-note.md"),
            isBookmarked: false
        )
        let updated = Note(
            id: id,
            filename: "My Note",
            tags: [],
            body: "Swift actors and concurrency.\n\nAsync/await structured tasks.",
            fileURL: URL(fileURLWithPath: "/tmp/my-note.md"),
            isBookmarked: false
        )
        let other = makeNote(filename: "Gardening", body: "Water plants and use compost as fertilizer.")

        try await indexer.indexAll([original, other])
        try await indexer.indexNote(updated)

        // Old content (cooking) should no longer score this note highly.
        let cookingResults = try await indexer.search(query: "pasta cooking recipes", limit: 2)
        #expect(cookingResults.first != id, "Old cooking content must not dominate after re-index")

        // New content (Swift) should score this note first.
        let swiftResults = try await indexer.search(query: "Swift concurrency actors", limit: 2)
        #expect(swiftResults.first == id, "Re-indexed note should rank first for new content")
    }

}

// MARK: - Incremental sync

@Suite("NoteIndexer – incremental sync", .timeLimit(.minutes(5)))
struct NoteIndexerIncrementalSyncTests {

    func makeNote(id: UUID = UUID(), filename: String, body: String, tags: [String] = []) -> Note {
        Note(
            id: id,
            filename: filename,
            tags: tags,
            body: body,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"),
            isBookmarked: false
        )
    }

    func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("unchanged note is skipped on second indexAll")
    func unchangedNoteSkippedOnReindex() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Unchanged", body: "Swift programming language for macOS.")
        let indexer = NoteIndexer(storageDirectory: tmp)
        try await indexer.indexAll([note])
        let countAfterFirst = await indexer.indexedCount()

        try await indexer.indexAll([note])
        let countAfterSecond = await indexer.indexedCount()

        #expect(countAfterFirst == 1)
        #expect(countAfterSecond == 1)
        let results = try await indexer.search(query: "Swift macOS programming", limit: 1)
        #expect(results.first == note.id)
    }

    @Test("changed note is re-indexed after content update via indexAll")
    func changedNoteReindexedAfterContentUpdate() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = UUID()
        let original = makeNote(id: id, filename: "My Note", body: "Pasta recipe with tomato sauce.")
        let updated = makeNote(id: id, filename: "My Note", body: "Swift actors and structured concurrency.")

        let indexer = NoteIndexer(storageDirectory: tmp)
        try await indexer.indexAll([original])
        try await indexer.indexAll([updated])

        let results = try await indexer.search(query: "Swift concurrency actors", limit: 1)
        #expect(results.first == id, "Note should rank first for new content after re-index")
    }

    @Test("note missing from indexAll list is removed from search results")
    func deletedNoteRemovedOnIndexAll() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kept = makeNote(filename: "Kept", body: "Gardening and composting tips for spring.")
        let removed = makeNote(filename: "Removed", body: "Swift programming with generics and protocols.")

        let indexer = NoteIndexer(storageDirectory: tmp)
        try await indexer.indexAll([kept, removed])
        try await indexer.indexAll([kept])

        let count = await indexer.indexedCount()
        #expect(count == 1)
        let results = try await indexer.search(query: "Swift generics protocols", limit: 5)
        #expect(results.contains(removed.id) == false, "Removed note must not appear in results")
    }

    @Test("resetAndClearIndex empties the vector index and makes search return empty")
    func resetAndClearIndexEmptiesIndex() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Note", body: "Swift language features and protocols.")
        let indexer = NoteIndexer(storageDirectory: tmp)
        try await indexer.indexAll([note])
        #expect(await indexer.indexedCount() == 1)

        await indexer.resetAndClearIndex()

        #expect(await indexer.indexedCount() == 0)
        let results = try await indexer.search(query: "Swift language", limit: 5)
        #expect(results.isEmpty, "Search must return empty after reset")
    }

    @Test("clearHashStore forces re-index on fresh indexer without loadFromDisk")
    func clearHashStoreTriggersReindexOnFreshStart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Note", body: "Swift programming language for iOS.")

        // Persist MD5 to DB via first indexer.
        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([note])

        // Fresh indexer in same dir without loadFromDisk — uuidToKeys is empty.
        // clearHashStore removes the stored MD5, so indexAll treats the note as new.
        let indexerB = NoteIndexer(storageDirectory: tmp)
        await indexerB.clearHashStore()
        try await indexerB.indexAll([note])

        let results = try await indexerB.search(query: "Swift iOS programming", limit: 1)
        #expect(results.first == note.id, "Note must be indexed and searchable after clearHashStore + indexAll")
    }
}

// MARK: - stripMarkdown unit tests

@Suite("NoteIndexer – stripMarkdown")
struct NoteIndexerStripMarkdownTests {

    @Test("plain text is unchanged")
    func plainTextUnchanged() {
        let input = "Hello world.\nThis is a plain note."
        #expect(NoteIndexer.stripMarkdown(input) == input)
    }

    @Test("ATX headings: # markers removed, text kept", arguments: [
        ("# Title", "Title"),
        ("## Section", "Section"),
        ("### Sub-section", "Sub-section"),
        ("###### H6", "H6"),
    ])
    func headingsStripped(input: String, expected: String) {
        #expect(NoteIndexer.stripMarkdown(input) == expected)
    }

    @Test("bold **text** markers removed")
    func boldAsteriskStripped() {
        #expect(NoteIndexer.stripMarkdown("This is **bold** text.") == "This is bold text.")
    }

    @Test("bold __text__ markers removed")
    func boldUnderscoreStripped() {
        #expect(NoteIndexer.stripMarkdown("This is __bold__ text.") == "This is bold text.")
    }

    @Test("italic *text* markers removed")
    func italicAsteriskStripped() {
        #expect(NoteIndexer.stripMarkdown("This is *italic* text.") == "This is italic text.")
    }

    @Test("italic _text_ markers removed")
    func italicUnderscoreStripped() {
        #expect(NoteIndexer.stripMarkdown("This is _italic_ text.") == "This is italic text.")
    }

    @Test("strikethrough ~~text~~ markers removed")
    func strikethroughStripped() {
        #expect(NoteIndexer.stripMarkdown("~~deleted text~~") == "deleted text")
    }

    @Test("inline code: backticks removed, content kept")
    func inlineCodeContentKept() {
        #expect(NoteIndexer.stripMarkdown("Use `await` here.") == "Use await here.")
    }

    @Test("fenced code block: fence markers removed, code content kept")
    func codeFenceContentKept() {
        let input = "```swift\nlet x = 42\nprint(x)\n```"
        let result = NoteIndexer.stripMarkdown(input)
        #expect(result.contains("let x = 42"))
        #expect(result.contains("print(x)"))
        #expect(result.contains("```") == false)
    }

    @Test("images removed entirely")
    func imagesRemoved() {
        let result = NoteIndexer.stripMarkdown("See ![diagram](diagram.png) for reference.")
        #expect(result.contains("![") == false)
        #expect(result.contains("diagram.png") == false)
        #expect(result.contains("See"))
        #expect(result.contains("for reference."))
    }

    @Test("markdown links: URL removed, link text kept")
    func linksTextKept() {
        #expect(NoteIndexer.stripMarkdown("Read [the docs](https://example.com).") == "Read the docs.")
    }

    @Test("wikilinks: brackets removed, target name kept")
    func wikilinksNameKept() {
        #expect(NoteIndexer.stripMarkdown("See [[Swift Concurrency]] for details.") == "See Swift Concurrency for details.")
    }

    @Test("blockquote > markers removed")
    func blockquotesStripped() {
        #expect(NoteIndexer.stripMarkdown("> A quoted line.") == "A quoted line.")
    }

    @Test("horizontal rules removed")
    func horizontalRulesRemoved() {
        let result = NoteIndexer.stripMarkdown("Before\n---\nAfter")
        #expect(!result.contains("---"))
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
    }

    @Test("task list markers removed, item text kept", arguments: [
        ("- [ ] Buy milk", "Buy milk"),
        ("- [x] Write tests", "Write tests"),
        ("- [X] Deploy", "Deploy"),
    ])
    func taskListMarkersStripped(input: String, expected: String) {
        #expect(NoteIndexer.stripMarkdown(input) == expected)
    }

    @Test("HTML tags removed", arguments: [
        ("<em>text</em>", "text"),
        ("<br>", ""),
    ])
    func htmlTagsRemoved(input: String, expected: String) {
        #expect(NoteIndexer.stripMarkdown(input) == expected)
    }

    @Test("mixed markdown document: all markers stripped, content preserved")
    func mixedDocumentStripped() {
        let input = """
        # Meeting Notes

        **Action items** for *next sprint*:
        - Use `actor` for state isolation.

        > Remember to update [[Architecture Decisions]].

        See [WWDC talk](https://developer.apple.com) for details.
        """
        let result = NoteIndexer.stripMarkdown(input)
        #expect(result.contains("Meeting Notes"))
        #expect(result.contains("Action items"))
        #expect(result.contains("next sprint"))
        #expect(result.contains("actor"))
        #expect(result.contains("Remember to update"))
        #expect(result.contains("Architecture Decisions"))
        #expect(result.contains("WWDC talk"))
        #expect(result.contains("**") == false)
        #expect(result.contains("[[") == false)
        #expect(result.contains("](") == false)
    }
}

// MARK: - loadFromDisk regression

@Suite("NoteIndexer – loadFromDisk", .timeLimit(.minutes(5)))
struct NoteIndexerLoadFromDiskTests {

    func makeNote(filename: String, body: String) -> Note {
        Note(
            id: UUID(),
            filename: filename,
            tags: [],
            body: body,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"),
            isBookmarked: false
        )
    }

    /// Regression: vectorIndex.add() crashed after loadFromDisk because USearch does not
    /// persist thread-slot structures to disk. reserve() must be called after load().
    @Test("indexNote does not crash after loadFromDisk (thread-slot regression)")
    func indexNoteAfterLoadFromDiskDoesNotCrash() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = makeNote(filename: "Regression Note", body: "USearch thread slot regression test.")

        // First run: index a note and persist to disk.
        let indexerA = NoteIndexer(storageDirectory: tmp)
        try await indexerA.indexAll([note])

        // Second run: simulate app relaunch — load from disk, then index a new note.
        let indexerB = NoteIndexer(storageDirectory: tmp)
        await indexerB.loadFromDisk()

        let updated = makeNote(filename: note.filename, body: "Updated body after reload.")
        // This must not crash with USearch thread_lock_ error.
        try await indexerB.indexNote(updated)

        let results = try await indexerB.search(query: "updated reload", limit: 1)
        #expect(results.isEmpty == false, "Note indexed after loadFromDisk should be searchable")
    }
}

// MARK: - BM25 search tests

@Suite("NoteIndexer – BM25 search", .timeLimit(.minutes(5)))
struct NoteIndexerBM25Tests {

    private func makeNote(filename: String, body: String, tags: [String] = []) -> Note {
        Note(id: UUID(), filename: filename, tags: tags, body: body,
             fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"), isBookmarked: false)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("BM25 returns exact keyword match as first result")
    func bm25ReturnsKeywordMatch() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let swift = makeNote(filename: "Swift", body: "Swift actors and structured concurrency.")
        let recipe = makeNote(filename: "Pasta", body: "Boil water and add tomato sauce to spaghetti.")
        try await indexer.indexAll([swift, recipe])
        let results = await indexer.searchBM25Ranked(query: "tomato sauce spaghetti", limit: 5)
        #expect(results.first?.id == recipe.id)
    }

    @Test("BM25 returns empty for operator-only query")
    func bm25EmptyForOperatorOnlyQuery() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let note = makeNote(filename: "Note", body: "Some content here.")
        try await indexer.indexAll([note])
        let results = await indexer.searchBM25Ranked(query: "***---", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("removeNote removes its FTS entry")
    func removeNoteRemovesFTSEntry() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let note = makeNote(filename: "Removable", body: "unique-keyword-xyzzy content")
        try await indexer.indexAll([note])
        await indexer.removeNote(id: note.id)
        let results = await indexer.searchBM25Ranked(query: "unique-keyword-xyzzy", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("re-indexing updates FTS content")
    func reindexUpdatesFTSContent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let id = UUID()
        let original = Note(id: id, filename: "Note", tags: [], body: "cooking pasta tomato",
                            fileURL: URL(fileURLWithPath: "/tmp/Note.md"), isBookmarked: false)
        let updated = Note(id: id, filename: "Note", tags: [], body: "swift concurrency actors",
                           fileURL: URL(fileURLWithPath: "/tmp/Note.md"), isBookmarked: false)
        try await indexer.indexAll([original])
        try await indexer.indexNote(updated)
        let oldResults = await indexer.searchBM25Ranked(query: "tomato pasta", limit: 5)
        #expect(oldResults.first?.id != id)
        let newResults = await indexer.searchBM25Ranked(query: "swift actors", limit: 5)
        #expect(newResults.first?.id == id)
    }
}
