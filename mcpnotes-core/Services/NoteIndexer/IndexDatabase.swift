import Foundation
import SQLite3

/// SQLite-backed store for chunk-key mappings and per-note content hashes.
/// Replaces notes-keys.json; lives alongside notes.usearch in Application Support.
final class IndexDatabase: @unchecked Sendable {
    nonisolated(unsafe) private var db: OpaquePointer?
    private nonisolated let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        sqlite3_open_v2(url.path, &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS note_chunks (
                uuid      TEXT    NOT NULL,
                chunk_key INTEGER NOT NULL,
                PRIMARY KEY (uuid, chunk_key)
            );
            CREATE TABLE IF NOT EXISTS file_hashes (
                uuid TEXT PRIMARY KEY,
                md5  TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                uuid UNINDEXED,
                content,
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS note_tags (
                uuid TEXT NOT NULL,
                tag  TEXT NOT NULL,
                PRIMARY KEY (uuid, tag)
            );
            CREATE TABLE IF NOT EXISTS note_meta (
                uuid     TEXT PRIMARY KEY,
                filename TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS note_links (
                source_uid TEXT NOT NULL,
                target_uid TEXT NOT NULL,
                PRIMARY KEY (source_uid, target_uid)
            );
            """, nil, nil, nil)
        let linksVersion = intMeta("links_schema_version") ?? 0
        if linksVersion < 1 {
            clearHashes()
            setMeta("links_schema_version", 1)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: meta

    nonisolated func intMeta(_ key: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    nonisolated func setMeta(_ key: String, _ value: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_int64(stmt, 2, Int64(value))
        sqlite3_step(stmt)
    }

    // MARK: note_chunks

    nonisolated func chunkKeys(for uuid: UUID) -> [UInt64] {
        var stmt: OpaquePointer?
        let uuidStr = uuid.uuidString
        guard sqlite3_prepare_v2(db, "SELECT chunk_key FROM note_chunks WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuidStr, -1, transient)
        var keys: [UInt64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            keys.append(UInt64(bitPattern: sqlite3_column_int64(stmt, 0)))
        }
        return keys
    }

    nonisolated func allUUIDs() -> Set<UUID> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT uuid FROM note_chunks", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var uuids: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr)) {
                uuids.insert(uuid)
            }
        }
        return uuids
    }

    nonisolated func setChunkKeys(_ keys: [UInt64], for uuid: UUID) {
        let uuidStr = uuid.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM note_chunks WHERE uuid = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, uuidStr, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO note_chunks (uuid, chunk_key) VALUES (?, ?)", -1, &insStmt, nil) == SQLITE_OK {
            for key in keys {
                sqlite3_bind_text(insStmt, 1, uuidStr, -1, transient)
                sqlite3_bind_int64(insStmt, 2, Int64(bitPattern: key))
                sqlite3_step(insStmt)
                sqlite3_reset(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func removeChunks(for uuid: UUID) {
        var stmt: OpaquePointer?
        let uuidStr = uuid.uuidString
        guard sqlite3_prepare_v2(db, "DELETE FROM note_chunks WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuidStr, -1, transient)
        sqlite3_step(stmt)
    }

    // MARK: file_hashes

    nonisolated func md5(for uuid: UUID) -> String? {
        var stmt: OpaquePointer?
        let uuidStr = uuid.uuidString
        guard sqlite3_prepare_v2(db, "SELECT md5 FROM file_hashes WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuidStr, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    nonisolated func setMD5(_ md5: String, for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO file_hashes (uuid, md5) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, md5, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func removeMD5(for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM file_hashes WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func clearHashes() {
        sqlite3_exec(db, "DELETE FROM file_hashes", nil, nil, nil)
    }

    nonisolated func maxChunkKey() -> UInt64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(chunk_key) FROM note_chunks", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let raw = sqlite3_column_int64(stmt, 0)
        return raw == 0 ? nil : UInt64(bitPattern: raw)
    }

    // MARK: notes_fts

    nonisolated func insertFTS(uuid: UUID, content: String) {
        let uuidStr = uuid.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM notes_fts WHERE uuid = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, uuidStr, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO notes_fts(uuid, content) VALUES (?, ?)", -1, &insStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(insStmt, 1, uuidStr, -1, transient)
            sqlite3_bind_text(insStmt, 2, content, -1, transient)
            sqlite3_step(insStmt)
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func deleteFTS(uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM notes_fts WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func clearFTS() {
        sqlite3_exec(db, "DELETE FROM notes_fts", nil, nil, nil)
    }

    // MARK: note_tags

    nonisolated func upsertTags(_ tags: [String], for uuid: UUID) {
        let uuidStr = uuid.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM note_tags WHERE uuid = ?", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, uuidStr, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO note_tags (uuid, tag) VALUES (?, ?)", -1, &insStmt, nil) == SQLITE_OK {
            for tag in tags {
                sqlite3_bind_text(insStmt, 1, uuidStr, -1, transient)
                sqlite3_bind_text(insStmt, 2, tag, -1, transient)
                sqlite3_step(insStmt)
                sqlite3_reset(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func removeTags(for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM note_tags WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    // MARK: note_meta

    nonisolated func upsertMeta(filename: String, for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO note_meta (uuid, filename) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, filename, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func removeMeta(for uuid: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM note_meta WHERE uuid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func filenameForID(_ id: UUID) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT filename FROM note_meta WHERE uuid = ?",
                                  -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    nonisolated func searchFTS(query: String, limit: Int) -> [(UUID, Double)] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT uuid, bm25(notes_fts) FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts) LIMIT ?",
            -1, &stmt, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sanitized, -1, transient)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var results: [(UUID, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: cStr)) else { continue }
            results.append((uuid, sqlite3_column_double(stmt, 1)))
        }
        return results
    }

    private nonisolated func sanitizeFTSQuery(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !"\"*()-^:\\".contains(Character($0)) }
        return String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated func clearAll() {
        sqlite3_exec(db,
            "DELETE FROM note_chunks; DELETE FROM file_hashes; DELETE FROM meta; DELETE FROM notes_fts; DELETE FROM note_tags; DELETE FROM note_meta; DELETE FROM note_links",
            nil, nil, nil)
    }

    // MARK: note_links

    nonisolated func resolveFilename(_ name: String) -> UUID? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT uuid FROM note_meta WHERE LOWER(filename) = LOWER(?)",
                                  -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return UUID(uuidString: String(cString: cStr))
    }

    nonisolated func setLinks(source: UUID, targets: [UUID]) {
        let src = source.uuidString
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM note_links WHERE source_uid = ?",
                               -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, src, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO note_links (source_uid, target_uid) VALUES (?, ?)",
                               -1, &insStmt, nil) == SQLITE_OK {
            for target in targets {
                sqlite3_bind_text(insStmt, 1, src, -1, transient)
                sqlite3_bind_text(insStmt, 2, target.uuidString, -1, transient)
                sqlite3_step(insStmt)
                sqlite3_reset(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    nonisolated func outgoingLinks(from source: UUID) -> [UUID] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT target_uid FROM note_links WHERE source_uid = ?",
                                  -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source.uuidString, -1, transient)
        var result: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr)) {
                result.append(uuid)
            }
        }
        return result
    }

    nonisolated func incomingLinks(to target: UUID) -> [UUID] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source_uid FROM note_links WHERE target_uid = ?",
                                  -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, target.uuidString, -1, transient)
        var result: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr)) {
                result.append(uuid)
            }
        }
        return result
    }

    nonisolated func removeLinks(source: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM note_links WHERE source_uid = ?",
                                  -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source.uuidString, -1, transient)
        sqlite3_step(stmt)
    }

    nonisolated func allLinks() -> [(source: UUID, target: UUID)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source_uid, target_uid FROM note_links",
                                  -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [(source: UUID, target: UUID)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = sqlite3_column_text(stmt, 0), let t = sqlite3_column_text(stmt, 1),
               let src = UUID(uuidString: String(cString: s)),
               let tgt = UUID(uuidString: String(cString: t)) {
                result.append((source: src, target: tgt))
            }
        }
        return result
    }

    nonisolated func removeLinksTo(target: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM note_links WHERE target_uid = ?",
                                  -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, target.uuidString, -1, transient)
        sqlite3_step(stmt)
    }
}
