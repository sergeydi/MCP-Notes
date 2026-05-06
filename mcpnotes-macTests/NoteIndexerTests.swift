import Foundation
import Testing
@testable import mcpnotes_mac

/// Integration tests — download multilingual-e5-small (~115 MB) on first run.
/// Model is cached in ~/Library/Caches/huggingface after that.
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

        #expect(results.contains(ai.id) == false, "Removed note must not appear in results")
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

    // MARK: - Link graph expansion

    @Test("expand_links appends linked note after primary results")
    func expandLinksAppendsLinkedNote() async throws {
        let indexer = NoteIndexer()

        let source = makeNote(
            filename: "Daily Notes",
            body: "Today I studied [[Swift Concurrency]]."
        )
        let target = makeNote(
            filename: "Swift Concurrency",
            body: "Actors, async/await, and structured concurrency in Swift."
        )
        let unrelated = makeNote(
            filename: "Shopping List",
            body: "Buy milk and bread."
        )

        try await indexer.indexAll([source, target, unrelated])

        // limit: 1 — only source is primary; target must arrive solely via expand_links
        let results = try await indexer.search(query: "daily notes diary", limit: 1)

        #expect(results.first == source.id, "Source note should be primary result")
        #expect(results.contains(target.id), "Linked target should appear via expand_links")
        #expect(results.contains(unrelated.id) == false, "Unrelated note should not appear")
    }

    @Test("expand_links=false omits linked notes")
    func expandLinksFalseOmitsLinkedNotes() async throws {
        let indexer = NoteIndexer()

        let source = makeNote(
            filename: "Daily Notes",
            body: "Today I studied [[Swift Concurrency]]."
        )
        let target = makeNote(
            filename: "Swift Concurrency",
            body: "Actors, async/await, and structured concurrency."
        )

        try await indexer.indexAll([source, target])

        let results = try await indexer.search(query: "daily notes diary", limit: 1, expandLinks: false)

        #expect(results.count == 1, "Only primary result when expandLinks=false")
        #expect(results.contains(target.id) == false, "Linked note must not appear when expandLinks=false")
    }

    @Test("expand_links returns all linked targets from a hub note")
    func expandLinksAllTargetsFromHub() async throws {
        let indexer = NoteIndexer()

        let hub = makeNote(
            filename: "Hub",
            body: "Central note. See [[Topic A]] and [[Topic B]] for details."
        )
        let topicA = makeNote(filename: "Topic A", body: "Detailed content about topic A.")
        let topicB = makeNote(filename: "Topic B", body: "Detailed content about topic B.")
        let unrelated = makeNote(filename: "Gardening", body: "Water plants every morning.")

        try await indexer.indexAll([hub, topicA, topicB, unrelated])

        let results = try await indexer.search(query: "central hub details", limit: 1)

        #expect(results.first == hub.id, "Hub should be primary")
        #expect(results.contains(topicA.id), "Topic A should appear via expand_links")
        #expect(results.contains(topicB.id), "Topic B should appear via expand_links")
        #expect(!results.contains(unrelated.id), "Unrelated note must not appear")
    }

    @Test("expand_links tolerates unresolvable wikilinks")
    func expandLinksToleratesUnresolvableLinks() async throws {
        let indexer = NoteIndexer()

        let note = makeNote(
            filename: "My Note",
            body: "References [[Nonexistent Note]] which was never indexed."
        )

        try await indexer.indexAll([note])

        let results = try await indexer.search(query: "references nonexistent", limit: 1)

        #expect(results.contains(note.id))
        #expect(results.count == 1, "No phantom entries for unresolvable links")
    }

    @Test("expand_links is one-directional: backlinks are not expanded")
    func expandLinksIsOneDirectional() async throws {
        let indexer = NoteIndexer()

        let diary = makeNote(
            filename: "Diary",
            body: "Today was a great day. See [[Machine Learning]] for study notes."
        )
        let ml = makeNote(
            filename: "Machine Learning",
            body: "Machine learning involves training models on data to make predictions."
        )

        try await indexer.indexAll([diary, ml])

        // Query strongly matches ml; diary should not appear via backlink expansion
        let results = try await indexer.search(query: "machine learning models predictions", limit: 1)

        #expect(results.first == ml.id, "ML note should be primary")
        #expect(results.contains(diary.id) == false, "Diary must not appear — backlinks are not tracked")
    }

    @Test("expand_links is shallow: linked notes' links are not recursively expanded")
    func expandLinksIsShallow() async throws {
        let indexer = NoteIndexer()

        let a = makeNote(filename: "Start", body: "Start here. See [[Middle]].")
        let b = makeNote(filename: "Middle", body: "Middle note. See [[Deep]].")
        let c = makeNote(filename: "Deep", body: "Deep note about cooking and pasta recipes.")

        try await indexer.indexAll([a, b, c])

        // "start here" matches a; b should expand in; c is 2 hops away and must not appear
        let results = try await indexer.search(query: "start here begin", limit: 1)

        #expect(results.first == a.id, "Start note should be primary")
        #expect(results.contains(b.id), "Middle should appear via expand_links (1 hop)")
        #expect(results.contains(c.id) == false, "Deep must not appear (2 hops, not expanded)")
    }

    @Test("expand_links expands links from multiple primary results")
    func expandLinksExpandsFromMultiplePrimary() async throws {
        let indexer = NoteIndexer()

        let a = makeNote(filename: "Overview Alpha", body: "Overview note alpha. See [[Detail X]].")
        let b = makeNote(filename: "Overview Beta", body: "Overview note beta. See [[Detail Y]].")
        let detailX = makeNote(filename: "Detail X", body: "Specifics about X topic.")
        let detailY = makeNote(filename: "Detail Y", body: "Specifics about Y topic.")

        try await indexer.indexAll([a, b, detailX, detailY])

        // Both overview notes are primary; their respective details expand in
        let results = try await indexer.search(query: "overview note", limit: 2)

        #expect(results.contains(detailX.id), "Detail X should appear via expand_links from Alpha")
        #expect(results.contains(detailY.id), "Detail Y should appear via expand_links from Beta")
    }

    @Test("expand_links does not duplicate already-found notes")
    func expandLinksNoDuplicates() async throws {
        let indexer = NoteIndexer()

        let a = makeNote(
            filename: "Note A",
            body: "Swift concurrency is great. See also [[Note B]]."
        )
        let b = makeNote(
            filename: "Note B",
            body: "Swift actors enable safe concurrent state."
        )

        try await indexer.indexAll([a, b])

        let results = try await indexer.search(query: "Swift concurrency actors", limit: 2)

        let uniqueIDs = Set(results)
        #expect(uniqueIDs.count == results.count, "No duplicate UUIDs in results")
    }

    @Test("expand_links skips notes removed from index")
    func expandLinksSkipsRemovedNotes() async throws {
        let indexer = NoteIndexer()

        let source = makeNote(
            filename: "Reference",
            body: "See [[Deleted Note]] for details."
        )
        let deleted = makeNote(
            filename: "Deleted Note",
            body: "This note will be removed."
        )

        try await indexer.indexAll([source, deleted])
        await indexer.removeNote(id: deleted.id)

        let results = try await indexer.search(query: "reference details", limit: 2)

        #expect(results.contains(deleted.id) == false, "Removed note must not appear via expand_links")
    }

    // MARK: - Wikilinks

    @Test("wikilink target name boosts ranking")
    func wikilinkBoostsRanking() async throws {
        let indexer = NoteIndexer()

        let linked = makeNote(
            filename: "Daily Notes",
            body: "Today I read about [[Swift Programming]] and took some notes."
        )
        let unrelated = makeNote(
            filename: "Shopping List",
            body: "Buy milk, eggs, and bread."
        )

        try await indexer.indexAll([linked, unrelated])

        let results = try await indexer.search(query: "Swift Programming language", limit: 2)
        #expect(results.first == linked.id, "Note with wikilink to Swift Programming should rank first")
    }

    @Test("multiple wikilinks are all indexed")
    func multipleWikilinksAreIndexed() async throws {
        let indexer = NoteIndexer()

        let linked = makeNote(
            filename: "Index",
            body: "See also [[Actors]] and [[Async Await]] for concurrency topics."
        )
        let unrelated = makeNote(
            filename: "Recipe",
            body: "Chop vegetables and simmer in broth for 20 minutes."
        )

        try await indexer.indexAll([linked, unrelated])

        let results = try await indexer.search(query: "actors async concurrency Swift", limit: 2)
        #expect(results.first == linked.id, "Note with multiple concurrency wikilinks should rank first")
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
        #expect(!result.contains("```"))
    }

    @Test("images removed entirely")
    func imagesRemoved() {
        let result = NoteIndexer.stripMarkdown("See ![diagram](diagram.png) for reference.")
        #expect(!result.contains("!["))
        #expect(!result.contains("diagram.png"))
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
        #expect(!result.contains("**"))
        #expect(!result.contains("[["))
        #expect(!result.contains("]("))
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
        #expect(!results.isEmpty, "Note indexed after loadFromDisk should be searchable")
    }
}
