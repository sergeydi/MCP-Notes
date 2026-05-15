import Foundation
import MCP
import Testing

// MARK: - Helpers

extension Tool.Content {
    var textValue: String? {
        if case .text(let t, _, _) = self { return t }
        return nil
    }
}

extension CallTool.Result {
    var firstText: String? { content.first?.textValue }
}

// MARK: - Test infrastructure

struct Fixture {
    let dir: URL
    let service: NotesService

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        service = NotesService(directory: dir)
    }

    @discardableResult
    func add(filename: String, tags: [String] = [], body: String = "") throws -> UUID {
        let uid = UUID()
        let content = FrontmatterParser.serialize(uid: uid, tags: tags, body: body)
        try content.write(
            to: dir.appendingPathComponent("\(filename).md"),
            atomically: true, encoding: .utf8
        )
        return uid
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private actor MockRAGSearcher: RAGSearching {
    private(set) var ready = false
    private(set) var stubbedResults: [(uuid: UUID, score: Float)] = []
    private(set) var stubbedTags: [(tag: String, count: Int)] = []
    private(set) var stubbedNotesByTag: [String: [(uuid: UUID, filename: String)]] = [:]

    var isReady: Bool { ready }

    func searchRanked(query: String, limit: Int) async throws -> [(uuid: UUID, score: Float)] {
        Array(stubbedResults.prefix(limit))
    }

    func searchRankedHybrid(query: String, limit: Int) async throws -> [HybridSearchResult] {
        stubbedResults.prefix(limit).enumerated().map { i, hit in
            HybridSearchResult(
                uuid: hit.uuid,
                vectorScore: hit.score,
                vectorRank: i + 1,
                bm25Rank: i + 1,
                hybridScore: Double(hit.score)
            )
        }
    }

    func allTags() async -> [(tag: String, count: Int)] { stubbedTags }
    func notes(forTag tag: String) async -> [(uuid: UUID, filename: String)] {
        stubbedNotesByTag[tag] ?? []
    }

    func setReady() { ready = true }
    func setResults(_ r: [(uuid: UUID, score: Float)]) { ready = true; stubbedResults = r }
    func setTags(_ t: [(tag: String, count: Int)]) { ready = true; stubbedTags = t }
    func setNotes(forTag tag: String, _ notes: [(uuid: UUID, filename: String)]) {
        ready = true; stubbedNotesByTag[tag] = notes
    }
}

@discardableResult
private func call(
    _ name: String,
    args: [String: Value] = [:],
    fixture: Fixture,
    rag: MockRAGSearcher = MockRAGSearcher()
) async throws -> CallTool.Result {
    let params = CallTool.Parameters(name: name, arguments: args)
    return try await NotesToolHandler.call(params, service: fixture.service, searcher: rag)
}

// MARK: - list_tags

@Suite("list_tags") final class ListTagsTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    // MARK: fallback path (index not ready)

    @Test func fallbackEmptyWhenNoNotes() async throws {
        let result = try await call("list_tags", fixture: fixture)
        #expect(result.firstText == "No tags found.")
        #expect(result.isError != true)
    }

    @Test func fallbackCountsAndSort() async throws {
        try fixture.add(filename: "A", tags: ["swift", "ios"])
        try fixture.add(filename: "B", tags: ["swift"])
        try fixture.add(filename: "C", tags: ["ios"])
        let text = try #require(try await call("list_tags", fixture: fixture).firstText)
        #expect(text.contains("ios (2)"))
        #expect(text.contains("swift (2)"))
        let lines = text.components(separatedBy: "\n")
        let iosIdx = lines.firstIndex(where: { $0.hasPrefix("ios") }) ?? 0
        let swiftIdx = lines.firstIndex(where: { $0.hasPrefix("swift") }) ?? 1
        #expect(iosIdx < swiftIdx)
    }

    // MARK: index path (index ready)

    @Test func indexPathReturnsTagsFromSearcher() async throws {
        let rag = MockRAGSearcher()
        await rag.setTags([("ios", 3), ("swift", 2)])
        let text = try #require(try await call("list_tags", fixture: fixture, rag: rag).firstText)
        #expect(text.contains("ios (3)"))
        #expect(text.contains("swift (2)"))
    }

    @Test func indexPathEmptyReturnsNoTagsMessage() async throws {
        let rag = MockRAGSearcher()
        await rag.setTags([])
        let result = try await call("list_tags", fixture: fixture, rag: rag)
        #expect(result.firstText == "No tags found.")
    }
}

// MARK: - list_notes_by_tag

@Suite("list_notes_by_tag") final class ListNotesByTagTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    // MARK: fallback path (index not ready)

    @Test func fallbackMatch() async throws {
        let uid = try fixture.add(filename: "Tagged", tags: ["work"])
        try fixture.add(filename: "Other", tags: ["personal"])
        let text = try #require(try await call("list_notes_by_tag", args: ["tag": .string("work")], fixture: fixture).firstText)
        #expect(text.contains(uid.uuidString))
        #expect(text.contains("Other") == false)
    }

    @Test(arguments: zip(["swift", "ios-dev"], ["missing", "ios"]))
    func fallbackNoMatchReturnsMessage(noteTag: String, searchTag: String) async throws {
        try fixture.add(filename: "Note", tags: [noteTag])
        let result = try await call("list_notes_by_tag", args: ["tag": .string(searchTag)], fixture: fixture)
        let text = try #require(result.firstText)
        #expect(text.contains("No notes found"))
    }

    @Test func missingArg() async throws {
        let result = try await call("list_notes_by_tag", fixture: fixture)
        #expect(result.isError == true)
    }

    // MARK: index path (index ready)

    @Test func indexPathReturnsNotesFromSearcher() async throws {
        let uid1 = UUID()
        let uid2 = UUID()
        let rag = MockRAGSearcher()
        await rag.setNotes(forTag: "work", [(uuid: uid1, filename: "Alpha"), (uuid: uid2, filename: "Zebra")])
        let text = try #require(try await call("list_notes_by_tag", args: ["tag": .string("work")], fixture: fixture, rag: rag).firstText)
        #expect(text.contains(uid1.uuidString))
        #expect(text.contains("Alpha"))
        #expect(text.contains(uid2.uuidString))
        #expect(text.contains("Zebra"))
    }

    @Test func indexPathNoMatchReturnsMessage() async throws {
        let rag = MockRAGSearcher()
        await rag.setReady()
        let result = try await call("list_notes_by_tag", args: ["tag": .string("nonexistent")], fixture: fixture, rag: rag)
        let text = try #require(result.firstText)
        #expect(text.contains("No notes found"))
    }
}

// MARK: - list_notes

@Suite("list_notes") final class ListNotesTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func empty() async throws {
        let result = try await call("list_notes", fixture: fixture)
        #expect(result.firstText == "No notes found.")
    }

    @Test func sortedByFilename() async throws {
        try fixture.add(filename: "Zebra")
        try fixture.add(filename: "Alpha")
        try fixture.add(filename: "Mango")
        let text = try #require(try await call("list_notes", fixture: fixture).firstText)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let names = lines.compactMap { $0.components(separatedBy: "  ").last }
        #expect(names == ["Alpha", "Mango", "Zebra"])
    }
}

// MARK: - search_notes

@Suite("search_notes") final class SearchNotesTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func byFilename() async throws {
        let uid = try fixture.add(filename: "SwiftUI Tips")
        try fixture.add(filename: "Unrelated")
        let text = try #require(try await call("search_notes", args: ["query": .string("swiftui")], fixture: fixture).firstText)
        #expect(text.contains(uid.uuidString))
        #expect(text.contains("Unrelated") == false)
    }

    @Test func byBody() async throws {
        let uid = try fixture.add(filename: "Note", body: "Today I learned about Combine framework")
        try fixture.add(filename: "Other", body: "Something else entirely")
        let text = try #require(try await call("search_notes", args: ["query": .string("combine")], fixture: fixture).firstText)
        #expect(text.contains(uid.uuidString))
    }

    @Test func byTag() async throws {
        let uid = try fixture.add(filename: "Note", tags: ["xcode"])
        try fixture.add(filename: "Other", tags: ["vscode"])
        let text = try #require(try await call("search_notes", args: ["query": .string("xcode")], fixture: fixture).firstText)
        #expect(text.contains(uid.uuidString))
    }

    @Test func noMatch() async throws {
        try fixture.add(filename: "Note", body: "hello world")
        let result = try await call("search_notes", args: ["query": .string("zzznomatch")], fixture: fixture)
        let text = try #require(result.firstText)
        #expect(text.contains("No notes found"))
    }

    @Test func limitRespected() async throws {
        for i in 1...5 { try fixture.add(filename: "Match \(i)", body: "keyword") }
        let text = try #require(try await call("search_notes", args: ["query": .string("keyword"), "limit": 2], fixture: fixture).firstText)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
    }
}

// MARK: - get_note

@Suite("get_note") final class GetNoteTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func found() async throws {
        let uid = try fixture.add(filename: "My Note", tags: ["tag1"], body: "Note body here")
        let text = try #require(try await call("get_note", args: ["uid": .string(uid.uuidString)], fixture: fixture).firstText)
        #expect(text.contains("My Note"))
        #expect(text.contains(uid.uuidString))
        #expect(text.contains("tag1"))
        #expect(text.contains("Note body here"))
    }

    @Test(arguments: ["not-a-uuid", "00000000-0000-0000-0000-000000000000"])
    func returnsErrorForBadUID(_ uid: String) async throws {
        let result = try await call("get_note", args: ["uid": .string(uid)], fixture: fixture)
        #expect(result.isError == true)
    }
}

// MARK: - update_note

@Suite("update_note") final class UpdateNoteTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func success() async throws {
        let uid = try fixture.add(filename: "Editable", tags: ["keep"], body: "old body")
        let result = try await call(
            "update_note",
            args: ["uid": .string(uid.uuidString), "body": .string("new body")],
            fixture: fixture
        )
        #expect(result.isError != true)
        let updated = fixture.service.note(uid: uid)
        #expect(updated?.body == "new body")
        #expect(updated?.tags == ["keep"])
    }

    @Test func notFound() async throws {
        let result = try await call(
            "update_note",
            args: ["uid": .string(UUID().uuidString), "body": .string("x")],
            fixture: fixture
        )
        #expect(result.isError == true)
    }
}

// MARK: - find_note

@Suite("find_note") final class FindNoteTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func substringMatch() async throws {
        let uid = try fixture.add(filename: "SwiftUI Best Practices")
        try fixture.add(filename: "UIKit Legacy")
        let text = try #require(try await call("find_note", args: ["title": .string("swiftui")], fixture: fixture).firstText)
        #expect(text.contains(uid.uuidString))
        #expect(text.contains("UIKit") == false)
    }

    @Test func caseInsensitive() async throws {
        let uid = try fixture.add(filename: "Meeting Notes")
        let text = try #require(try await call("find_note", args: ["title": .string("MEETING")], fixture: fixture).firstText)
        #expect(text.contains(uid.uuidString))
    }

    @Test func noMatch() async throws {
        try fixture.add(filename: "Alpha")
        let result = try await call("find_note", args: ["title": .string("zzz")], fixture: fixture)
        let text = try #require(result.firstText)
        #expect(text.contains("No notes found"))
    }

    @Test func missingArg() async throws {
        let result = try await call("find_note", fixture: fixture)
        #expect(result.isError == true)
    }
}

// MARK: - create_note

@Suite("create_note") final class CreateNoteTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func createsNoteOnDisk() async throws {
        let result = try await call("create_note", args: ["title": "My New Note"], fixture: fixture)
        #expect(result.isError != true)
        let notes = fixture.service.loadAll()
        #expect(notes.count == 1)
        #expect(notes[0].filename == "My New Note")
    }

    @Test func returnsUID() async throws {
        let text = try #require(try await call("create_note", args: ["title": "Note"], fixture: fixture).firstText)
        let notes = fixture.service.loadAll()
        let uid = try #require(notes.first?.id)
        #expect(text.contains(uid.uuidString))
    }

    @Test func createsWithTagsAndBody() async throws {
        try await call(
            "create_note",
            args: ["title": "Tagged", "tags": .array([.string("swift"), .string("ios")]), "body": .string("Hello")],
            fixture: fixture
        )
        let note = try #require(fixture.service.loadAll().first)
        #expect(note.tags == ["swift", "ios"])
        #expect(note.body.contains("Hello"))
    }

    @Test func defaultsToEmptyTagsAndBody() async throws {
        try await call("create_note", args: ["title": "Bare"], fixture: fixture)
        let note = try #require(fixture.service.loadAll().first)
        #expect(note.tags.isEmpty)
        #expect(note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func filenameCollisionAddsNumericSuffix() async throws {
        try await call("create_note", args: ["title": "Dup"], fixture: fixture)
        try await call("create_note", args: ["title": "Dup"], fixture: fixture)
        try await call("create_note", args: ["title": "Dup"], fixture: fixture)
        let names = fixture.service.loadAll().map(\.filename).sorted()
        #expect(names == ["Dup", "Dup 1", "Dup 2"])
    }

    @Test func noteIsReadableByGetNote() async throws {
        try await call(
            "create_note",
            args: ["title": "Readable", "body": .string("check this")],
            fixture: fixture
        )
        let uid = try #require(fixture.service.loadAll().first?.id)
        let text = try #require(try await call("get_note", args: ["uid": .string(uid.uuidString)], fixture: fixture).firstText)
        #expect(text.contains("Readable"))
        #expect(text.contains("check this"))
    }

    @Test func missingTitleReturnsError() async throws {
        let result = try await call("create_note", fixture: fixture)
        #expect(result.isError == true)
    }

    @Test func emptyTitleReturnsError() async throws {
        let result = try await call("create_note", args: ["title": ""], fixture: fixture)
        #expect(result.isError == true)
    }
}

// MARK: - rag_search

@Suite("rag_search") final class RagSearchTests {
    let fixture: Fixture

    init() throws { fixture = try Fixture() }
    deinit { fixture.cleanup() }

    @Test func indexNotReady() async throws {
        let rag = MockRAGSearcher()
        let result = try await call("rag_search", args: ["query": .string("test")], fixture: fixture, rag: rag)
        #expect(result.isError == true)
        let text = try #require(result.firstText)
        #expect(text.contains("not available"))
    }

    @Test func returnsRankedResults() async throws {
        let uid1 = try fixture.add(filename: "Alpha Note")
        let uid2 = try fixture.add(filename: "Beta Note")
        let rag = MockRAGSearcher()
        await rag.setResults([(uuid: uid1, score: 0.9), (uuid: uid2, score: 0.7)])
        let text = try #require(try await call("rag_search", args: ["query": .string("test")], fixture: fixture, rag: rag).firstText)
        #expect(text.contains(uid1.uuidString))
        #expect(text.contains(uid2.uuidString))
        #expect(text.contains("0.900"))
    }

    @Test func limitRespected() async throws {
        var results: [(uuid: UUID, score: Float)] = []
        for i in 0..<5 {
            let uid = try fixture.add(filename: "Note \(i)")
            results.append((uuid: uid, score: Float(5 - i) / 5))
        }
        let rag = MockRAGSearcher()
        await rag.setResults(results)
        let text = try #require(try await call("rag_search", args: ["query": .string("x"), "limit": 2], fixture: fixture, rag: rag).firstText)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
    }

    @Test func noResults() async throws {
        let rag = MockRAGSearcher()
        await rag.setReady()
        let result = try await call("rag_search", args: ["query": .string("test")], fixture: fixture, rag: rag)
        let text = try #require(result.firstText)
        #expect(text.contains("No semantically similar"))
    }

    @Test func hybridOutputContainsVectorAndBM25Ranks() async throws {
        let uid1 = try fixture.add(filename: "Alpha Note")
        let rag = MockRAGSearcher()
        await rag.setResults([(uuid: uid1, score: 0.9)])
        let text = try #require(try await call("rag_search", args: ["query": .string("test")], fixture: fixture, rag: rag).firstText)
        #expect(text.contains("v:1"))
        #expect(text.contains("h:1"))
    }
}
