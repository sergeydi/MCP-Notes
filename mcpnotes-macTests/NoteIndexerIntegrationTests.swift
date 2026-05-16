import Foundation
import Testing
@testable import mcpnotes_mac

/// Integration tests — download multilingual-e5-small (~115 MB) on first run.
/// Model is cached in ~/Library/Caches/huggingface after that.
@Suite("NoteIndexer – integration", .timeLimit(.minutes(5)))
@MainActor
struct NoteIndexerIntegrationTests {

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

    @Test("chunking: note with relevant paragraph ranks above unrelated note")
    func chunkingBoostsRelevantParagraph() async throws {
        let indexer = NoteIndexer()

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

        let cookingResults = try await indexer.search(query: "pasta cooking recipes", limit: 2)
        #expect(cookingResults.first != id, "Old cooking content must not dominate after re-index")

        let swiftResults = try await indexer.search(query: "Swift concurrency actors", limit: 2)
        #expect(swiftResults.first == id, "Re-indexed note should rank first for new content")
    }
}
