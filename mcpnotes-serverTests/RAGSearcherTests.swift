import Foundation
import SQLite3
import Testing
import USearch

// MARK: - Helpers

/// Fixed unit vector matching the one stored by makeUsearchIndex (axis-0 = 1, rest = 0).
/// Avoids loading CoreML and its XPC services in test environments.
private func mockEmbedder(_ text: String) async throws -> [Float] {
    var v = [Float](repeating: 0, count: 384)
    v[0] = 1
    return v
}

private func makeTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

/// Creates a minimal `notes-index.db` with the given `index_version` meta value.
private func makeDB(at url: URL, version: Int) {
    var db: OpaquePointer?
    sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS note_chunks (
            uuid TEXT NOT NULL, chunk_key INTEGER NOT NULL,
            PRIMARY KEY (uuid, chunk_key)
        );
        CREATE TABLE IF NOT EXISTS note_tags (
            uuid TEXT NOT NULL, tag TEXT NOT NULL,
            PRIMARY KEY (uuid, tag)
        );
        CREATE TABLE IF NOT EXISTS note_meta (
            uuid TEXT PRIMARY KEY, filename TEXT NOT NULL
        );
        """, nil, nil, nil)
    sqlite3_exec(db, "INSERT INTO meta VALUES ('index_version', '\(version)')", nil, nil, nil)
}

private func addChunkKey(dbURL: URL, uuid: UUID, key: UInt64) {
    var db: OpaquePointer?
    sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO note_chunks (uuid, chunk_key) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
    sqlite3_bind_int64(stmt, 2, Int64(bitPattern: key))
    sqlite3_step(stmt)
}

/// Creates a `notes.usearch` file containing a single normalised unit vector at `key`.
private func makeUsearchIndex(at path: String, key: UInt64) {
    let index = USearchIndex.make(metric: .cos, dimensions: 384, connectivity: 16, quantization: .F32)
    index.reserve(8)
    var vector = [Float](repeating: 0, count: 384)
    vector[0] = 1  // already unit-length
    index.add(key: key, vector: vector)
    index.save(path: path)
}

private func addLinkData(dbURL: URL, sourceUID: UUID, targetUID: UUID) {
    var db: OpaquePointer?
    sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS note_links (source_uid TEXT NOT NULL, target_uid TEXT NOT NULL, PRIMARY KEY (source_uid, target_uid));", nil, nil, nil)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO note_links (source_uid, target_uid) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, sourceUID.uuidString, -1, transient)
    sqlite3_bind_text(stmt, 2, targetUID.uuidString, -1, transient)
    sqlite3_step(stmt)
}

private func addTagData(dbURL: URL, uuid: UUID, tags: [String], filename: String) {
    var db: OpaquePointer?
    sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(db) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var metaStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO note_meta (uuid, filename) VALUES (?, ?)", -1, &metaStmt, nil) == SQLITE_OK {
        sqlite3_bind_text(metaStmt, 1, uuid.uuidString, -1, transient)
        sqlite3_bind_text(metaStmt, 2, filename, -1, transient)
        sqlite3_step(metaStmt)
        sqlite3_finalize(metaStmt)
    }
    var tagStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO note_tags (uuid, tag) VALUES (?, ?)", -1, &tagStmt, nil) == SQLITE_OK {
        for tag in tags {
            sqlite3_bind_text(tagStmt, 1, uuid.uuidString, -1, transient)
            sqlite3_bind_text(tagStmt, 2, tag, -1, transient)
            sqlite3_step(tagStmt)
            sqlite3_reset(tagStmt)
        }
        sqlite3_finalize(tagStmt)
    }
}

/// Creates notes_fts table and inserts one row for hybrid search tests.
private func addFTSContent(dbURL: URL, uuid: UUID, content: String) {
    var db: OpaquePointer?
    sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts
        USING fts5(uuid UNINDEXED, content, tokenize='unicode61 remove_diacritics 2');
        """, nil, nil, nil)
    var stmt: OpaquePointer?
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_prepare_v2(db, "INSERT INTO notes_fts(uuid, content) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
    sqlite3_bind_text(stmt, 2, content, -1, transient)
    sqlite3_step(stmt)
}

// MARK: - Tests

@Suite("RAGSearcher – loading")
struct RAGSearcherLoadingTests {

    @Test func isReadyFalseWhenNoFiles() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let searcher = RAGSearcher(storageDirectory: tmp)
        #expect(await searcher.isReady == false)
    }

    @Test func isReadyFalseWhenVersionMismatch() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        makeDB(at: tmp.appendingPathComponent("notes-index.db"), version: 1)
        let searcher = RAGSearcher(storageDirectory: tmp)
        #expect(await searcher.isReady == false)
    }

    @Test func isReadyFalseWhenUsearchFileMissing() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        makeDB(at: tmp.appendingPathComponent("notes-index.db"), version: 8)  // must match RAGSearcher.currentIndexVersion (8)
        // No .usearch file created
        let searcher = RAGSearcher(storageDirectory: tmp)
        #expect(await searcher.isReady == false)
    }

    @Test func isReadyTrueAndChunkMappingPopulatedForValidIndex() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteID = UUID()
        let chunkKey: UInt64 = 42

        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)  // must match RAGSearcher.currentIndexVersion (8)
        addChunkKey(dbURL: dbURL, uuid: noteID, key: chunkKey)

        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: chunkKey)

        let searcher = RAGSearcher(storageDirectory: tmp)
        #expect(await searcher.isReady)
    }

    @Test func searchRankedReturnsEmptyWhenNotReady() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let searcher = RAGSearcher(storageDirectory: tmp, embedder: mockEmbedder)
        let results = try await searcher.searchRanked(query: "test", limit: 5)
        #expect(results.isEmpty)
    }

    @Test func reloadsWhenIndexAppearsAfterInit() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let searcher = RAGSearcher(storageDirectory: tmp)
        #expect(await searcher.isReady == false)

        // Simulate main app writing the index after the server started.
        let noteID = UUID()
        let chunkKey: UInt64 = 7
        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)
        addChunkKey(dbURL: dbURL, uuid: noteID, key: chunkKey)
        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: chunkKey)

        #expect(await searcher.isReady)
    }

    @Test func reloadsWhenIndexFileIsUpdated() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteID = UUID()
        let chunkKey: UInt64 = 1
        let dbURL = tmp.appendingPathComponent("notes-index.db")
        let usearchPath = tmp.appendingPathComponent("notes.usearch").path
        makeDB(at: dbURL, version: 8)  // must match RAGSearcher.currentIndexVersion (8)
        addChunkKey(dbURL: dbURL, uuid: noteID, key: chunkKey)
        makeUsearchIndex(at: usearchPath, key: chunkKey)

        let searcher = RAGSearcher(storageDirectory: tmp)
        #expect(await searcher.isReady)

        // Simulate main app re-saving the index (bump mod date without changing content).
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: usearchPath
        )

        // We can't inspect keyToUUID directly; isReady re-evaluating to true after a mod-date
        // bump is the best observable proxy for a successful reload.
        #expect(await searcher.isReady)
    }
}

// MARK: - Tag query tests

@Suite("RAGSearcher – tags")
struct RAGSearcherTagTests {

    @Test func allTagsReturnsCountsSortedAlphabetically() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)

        let uid1 = UUID()
        let uid2 = UUID()
        let uid3 = UUID()
        addTagData(dbURL: dbURL, uuid: uid1, tags: ["swift", "ios"], filename: "Note A")
        addTagData(dbURL: dbURL, uuid: uid2, tags: ["swift"], filename: "Note B")
        addTagData(dbURL: dbURL, uuid: uid3, tags: ["ios"], filename: "Note C")

        let searcher = RAGSearcher(storageDirectory: tmp)
        let tags = await searcher.allTags()

        #expect(tags.count == 2)
        #expect(tags[0].tag == "ios")
        #expect(tags[0].count == 2)
        #expect(tags[1].tag == "swift")
        #expect(tags[1].count == 2)
    }

    @Test func allTagsReturnsEmptyWhenNoData() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        makeDB(at: tmp.appendingPathComponent("notes-index.db"), version: 8)
        let searcher = RAGSearcher(storageDirectory: tmp)
        let tags = await searcher.allTags()
        #expect(tags.isEmpty)
    }

    @Test func notesForTagReturnsMatchingNotesSortedByFilename() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)

        let uid1 = UUID()
        let uid2 = UUID()
        let uid3 = UUID()
        addTagData(dbURL: dbURL, uuid: uid1, tags: ["work"], filename: "Zebra")
        addTagData(dbURL: dbURL, uuid: uid2, tags: ["work"], filename: "Alpha")
        addTagData(dbURL: dbURL, uuid: uid3, tags: ["personal"], filename: "Other")

        let searcher = RAGSearcher(storageDirectory: tmp)
        let results = await searcher.notes(forTag: "work")

        #expect(results.count == 2)
        #expect(results[0].filename == "Alpha")
        #expect(results[0].uuid == uid2)
        #expect(results[1].filename == "Zebra")
        #expect(results[1].uuid == uid1)
    }

    @Test func notesForTagReturnsEmptyForUnknownTag() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)
        addTagData(dbURL: dbURL, uuid: UUID(), tags: ["swift"], filename: "Note")

        let searcher = RAGSearcher(storageDirectory: tmp)
        let results = await searcher.notes(forTag: "nonexistent")
        #expect(results.isEmpty)
    }
}

// MARK: - Hybrid search tests

@Suite("RAGSearcher – hybrid search")
struct RAGSearcherHybridTests {

    @Test func hybridReturnsEmptyWhenNotReady() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let searcher = RAGSearcher(storageDirectory: tmp, embedder: mockEmbedder)
        let results = try await searcher.searchRankedHybrid(query: "test", limit: 5)
        #expect(results.isEmpty)
    }

    @Test func hybridResultsContainVectorAndBM25Ranks() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noteID = UUID()
        let chunkKey: UInt64 = 1
        let dbURL = tmp.appendingPathComponent("notes-index.db")

        makeDB(at: dbURL, version: 8)
        addChunkKey(dbURL: dbURL, uuid: noteID, key: chunkKey)
        addFTSContent(dbURL: dbURL, uuid: noteID, content: "swift concurrency actors")
        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: chunkKey)

        let searcher = RAGSearcher(storageDirectory: tmp, embedder: mockEmbedder)
        #expect(await searcher.isReady)

        let results = try await searcher.searchRankedHybrid(query: "swift actors", limit: 5)
        #expect(!results.isEmpty)
        let first = results[0]
        #expect(first.uuid == noteID)
        #expect(first.vectorRank >= 1)
        #expect(first.bm25Rank != nil)
        #expect(first.hybridScore > 0)
    }

    // Verifies that the BM25 candidate pool (limit*5) is wider than the returned limit,
    // so a note ranked beyond `limit` in BM25 still receives a rank rather than nil.
    @Test func bm25RankAssignedWhenNoteExceedsNarrowLimit() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let limit = 2
        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)

        // Create limit+1 notes all containing "keyword".
        // The last one also gets a unique word; its chunk gets key 0 (unit vector),
        // so the single-entry USearch index will always return it as vector rank 1.
        var uuids: [UUID] = []
        for i in 0..<(limit + 1) {
            let uid = UUID()
            uuids.append(uid)
            let content = i < limit ? "keyword note\(i)" : "keyword unique targetNote"
            addFTSContent(dbURL: dbURL, uuid: uid, content: content)
            addChunkKey(dbURL: dbURL, uuid: uid, key: UInt64(i))
        }

        // Only the last note's chunk key (index `limit`) is in the USearch index.
        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: UInt64(limit))

        let searcher = RAGSearcher(storageDirectory: tmp, embedder: mockEmbedder)
        #expect(await searcher.isReady)

        // With limit=2, old bm25 limit would be 2 → the 3rd BM25 result gets nil.
        // With limit*5=10, all 3 notes are in the BM25 pool → vector rank-1 note gets a real rank.
        let results = try await searcher.searchRankedHybrid(query: "keyword", limit: limit)
        #expect(!results.isEmpty)
        let target = results.first { $0.uuid == uuids[limit] }
        #expect(target != nil)
        #expect(target?.bm25Rank != nil)
    }
}

@Suite("RAGSearcher – links")
struct RAGSearcherLinksTests {

    @Test func outgoingLinksReturnsMappedNotes() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("notes-index.db")
        let sourceUID = UUID()
        let targetUID = UUID()
        makeDB(at: dbURL, version: 8)
        addTagData(dbURL: dbURL, uuid: targetUID, tags: [], filename: "Target Note")
        addLinkData(dbURL: dbURL, sourceUID: sourceUID, targetUID: targetUID)
        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: 1)
        addChunkKey(dbURL: dbURL, uuid: targetUID, key: 1)

        let searcher = RAGSearcher(storageDirectory: tmp)
        let links = await searcher.outgoingLinks(from: sourceUID)
        #expect(links.count == 1)
        #expect(links.first?.uuid == targetUID)
        #expect(links.first?.filename == "Target Note")
    }

    @Test func incomingLinksReturnsMappedNotes() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("notes-index.db")
        let sourceUID = UUID()
        let targetUID = UUID()
        makeDB(at: dbURL, version: 8)
        addTagData(dbURL: dbURL, uuid: sourceUID, tags: [], filename: "Source Note")
        addLinkData(dbURL: dbURL, sourceUID: sourceUID, targetUID: targetUID)
        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: 1)
        addChunkKey(dbURL: dbURL, uuid: sourceUID, key: 1)

        let searcher = RAGSearcher(storageDirectory: tmp)
        let backlinks = await searcher.incomingLinks(to: targetUID)
        #expect(backlinks.count == 1)
        #expect(backlinks.first?.uuid == sourceUID)
        #expect(backlinks.first?.filename == "Source Note")
    }

    @Test func outgoingLinksEmptyWhenNoData() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("notes-index.db")
        makeDB(at: dbURL, version: 8)
        makeUsearchIndex(at: tmp.appendingPathComponent("notes.usearch").path, key: 1)
        addChunkKey(dbURL: dbURL, uuid: UUID(), key: 1)

        let searcher = RAGSearcher(storageDirectory: tmp)
        let links = await searcher.outgoingLinks(from: UUID())
        #expect(links.isEmpty)
    }
}
