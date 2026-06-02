import Foundation
import Testing
@testable import MCPNotesCore
@testable import mcpnotes_mac

@Suite("NoteIndexer – wikilink graph", .timeLimit(.minutes(5)), .serialized)
struct NoteIndexerWikilinkTests {

    private func makeNote(filename: String, body: String) -> Note {
        Note(id: UUID(), filename: filename, tags: [], body: body,
             fileURL: URL(fileURLWithPath: "/tmp/\(filename).md"), isBookmarked: false)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("outgoingLinks returns target UUID after indexAll with cross-note link")
    func outgoingLinksResolvedByIndexAll() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let target = makeNote(filename: "Swift Concurrency", body: "Actors and structured tasks.")
        let source = makeNote(filename: "Intro", body: "See [[Swift Concurrency]] for details.")
        try await indexer.indexAll([source, target])
        let links = await indexer.outgoingLinks(from: source.id)
        #expect(links == [target.id])
    }

    @Test("incomingLinks returns source UUID after indexAll")
    func incomingLinksResolvedByIndexAll() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let target = makeNote(filename: "Concurrency", body: "Swift concurrency concepts.")
        let source = makeNote(filename: "Overview", body: "See [[Concurrency]] for more.")
        try await indexer.indexAll([source, target])
        let backlinks = await indexer.incomingLinks(to: target.id)
        #expect(backlinks == [source.id])
    }

    @Test("link resolution is case-insensitive")
    func linkResolutionIsCaseInsensitive() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let target = makeNote(filename: "Swift Concurrency", body: "Actors.")
        let source = makeNote(filename: "Intro", body: "See [[swift concurrency]] here.")
        try await indexer.indexAll([source, target])
        let links = await indexer.outgoingLinks(from: source.id)
        #expect(links == [target.id])
    }

    @Test("unresolvable wikilink produces empty outgoing links, no error")
    func unresolvableLinkIsIgnored() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = IndexDatabase(url: tmp.appendingPathComponent("test.db"))
        let source = UUID()
        db.upsertMeta(filename: "Intro", for: source)
        // resolveFilename returns nil for unknown name → compactMap drops it
        let targets: [UUID] = ["NonExistentNote"].compactMap { db.resolveFilename($0) }
        db.setLinks(source: source, targets: targets)
        #expect(db.outgoingLinks(from: source).isEmpty)
    }

    @Test("indexNote resolves link when target is already indexed")
    func indexNoteResolvesLinkToExistingNote() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = IndexDatabase(url: tmp.appendingPathComponent("test.db"))
        let targetID = UUID()
        let sourceID = UUID()
        db.upsertMeta(filename: "Patterns", for: targetID)
        db.upsertMeta(filename: "Architecture", for: sourceID)
        let targets: [UUID] = ["Patterns"].compactMap { db.resolveFilename($0) }
        db.setLinks(source: sourceID, targets: targets)
        #expect(db.outgoingLinks(from: sourceID) == [targetID])
    }

    @Test("re-indexing with new body replaces old links")
    func reindexReplacesLinks() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let noteA = makeNote(filename: "A", body: "No links here.")
        let noteB = makeNote(filename: "B", body: "Target B content.")
        let noteC = makeNote(filename: "C", body: "Target C content.")
        try await indexer.indexAll([noteA, noteB, noteC])
        #expect(await indexer.outgoingLinks(from: noteA.id).isEmpty)
        let updatedA = Note(id: noteA.id, filename: "A", tags: [],
                            body: "Now links to [[B]] and [[C]].",
                            fileURL: noteA.fileURL, isBookmarked: false)
        try await indexer.indexNote(updatedA)
        let links = await indexer.outgoingLinks(from: updatedA.id)
        #expect(Set(links) == Set([noteB.id, noteC.id]))
    }

    @Test("removeNote clears its outgoing links")
    func removeNoteClearsOutgoingLinks() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let target = makeNote(filename: "Target", body: "Target content.")
        let source = makeNote(filename: "Source", body: "Links to [[Target]].")
        try await indexer.indexAll([source, target])
        #expect(await indexer.outgoingLinks(from: source.id) == [target.id])
        await indexer.removeNote(id: source.id)
        let links = await indexer.outgoingLinks(from: source.id)
        #expect(links.isEmpty)
    }

    @Test("removeNote clears incoming links pointing to it")
    func removeNoteClearsIncomingLinks() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let target = makeNote(filename: "Target", body: "Target content.")
        let source = makeNote(filename: "Source", body: "Links to [[Target]].")
        try await indexer.indexAll([source, target])
        #expect(await indexer.incomingLinks(to: target.id) == [source.id])
        await indexer.removeNote(id: target.id)
        let backlinks = await indexer.incomingLinks(to: target.id)
        #expect(backlinks.isEmpty)
    }

    @Test("rename cascade: re-indexing with new filename preserves link resolution")
    func renameCascadePreservesLinks() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexer = NoteIndexer(storageDirectory: tmp)
        let target = makeNote(filename: "Old", body: "The target.")
        let source = makeNote(filename: "Source", body: "See [[Old]] for details.")
        try await indexer.indexAll([source, target])
        #expect(await indexer.outgoingLinks(from: source.id) == [target.id])
        #expect(await indexer.incomingLinks(to: target.id) == [source.id])

        // Simulate NoteStore rename cascade: re-index target with new filename,
        // then re-index source with the updated wikilink body.
        let renamedTarget = Note(id: target.id, filename: "New", tags: [],
                                 body: target.body, fileURL: target.fileURL, isBookmarked: false)
        let updatedSource = Note(id: source.id, filename: "Source", tags: [],
                                 body: "See [[New]] for details.", fileURL: source.fileURL, isBookmarked: false)
        try await indexer.indexNote(renamedTarget)
        try await indexer.indexNote(updatedSource)

        #expect(await indexer.outgoingLinks(from: source.id) == [target.id])
        #expect(await indexer.incomingLinks(to: target.id) == [source.id])
    }

    @Test("note with no wikilinks has empty outgoing links")
    func noteWithNoWikilinksHasEmptyLinks() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = IndexDatabase(url: tmp.appendingPathComponent("test.db"))
        let noteID = UUID()
        db.upsertMeta(filename: "Plain", for: noteID)
        db.setLinks(source: noteID, targets: [])
        #expect(db.outgoingLinks(from: noteID).isEmpty)
        #expect(db.incomingLinks(to: noteID).isEmpty)
    }
}
