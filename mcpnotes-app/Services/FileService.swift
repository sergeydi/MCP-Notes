import Foundation

/// Handles reading and writing note files from the notes directory.
///
/// Notes are stored as flat `.md` files — no subdirectories. The preferred
/// location is the app's iCloud Drive container; the local Application Support
/// directory is used as a fallback during development without iCloud configured.
struct FileService: FileServicing {

    init() {}

    /// Root directory where all note files are stored.
    /// Priority: custom user-chosen folder > iCloud Drive > ~/Documents/MCP Notes.
    static var notesDirectoryURL: URL {
        if let url = activeCustomURL ?? resolveCustomNotesDirectory() {
            return url
        }
        if let icloudURL = icloudNotesURL() {
            return icloudURL
        }
        return localFallbackURL()
    }

    /// The currently active security-scoped custom directory URL, if set.
    static var customNotesDirectoryURL: URL? { activeCustomURL }

    /// Persists `url` as a security-scoped bookmark and activates it immediately.
    static func setCustomNotesDirectory(_ url: URL) throws {
        activeCustomURL?.stopAccessingSecurityScopedResource()
        activeCustomURL = nil
        let data = try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: customBookmarkKey)
        _ = url.startAccessingSecurityScopedResource()
        activeCustomURL = url
    }

    /// Removes the custom directory bookmark and reverts to the default location.
    static func clearCustomNotesDirectory() {
        activeCustomURL?.stopAccessingSecurityScopedResource()
        activeCustomURL = nil
        UserDefaults.standard.removeObject(forKey: customBookmarkKey)
    }

    /// Loads all notes, downloading any not-yet-local iCloud files first.
    /// Files download concurrently (one task per file) instead of relying on
    /// `String(contentsOf:)` to implicitly download each one in sequence — with many
    /// small notes that serial per-file network latency, not file size, is what makes
    /// a cold start slow on a freshly-signed-in device.
    func loadAllNotes() async throws -> [Note] {
        let files = try mdFiles()
        let notes = try await withThrowingTaskGroup(of: Note?.self) { group in
            for url in files {
                group.addTask { try await Self.readNote(at: url) }
            }
            var results: [Note] = []
            for try await note in group {
                if let note { results.append(note) }
            }
            return results
        }
        return notes.sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
    }

    /// Same directory scan as `loadAllNotes()`, but reads only what's needed to build
    /// `NoteMetadata` (including a bounded `preview` snippet) — never keeps a full body around.
    func loadAllNotesMetadata() async throws -> [NoteMetadata] {
        let files = try mdFiles()
        let metadata = try await withThrowingTaskGroup(of: NoteMetadata?.self) { group in
            for url in files {
                group.addTask { try await Self.readNoteMetadata(at: url) }
            }
            var results: [NoteMetadata] = []
            for try await item in group {
                if let item { results.append(item) }
            }
            return results
        }
        return metadata.sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
    }

    /// Loads a single note's full content on demand — used by the editor and by anything that
    /// needs one note's body (indexing worker, rename cascade) without holding the whole vault.
    func loadNote(at fileURL: URL) async throws -> Note {
        guard let note = try await Self.readNote(at: fileURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return note
    }

    private func mdFiles() throws -> [URL] {
        let dir = Self.notesDirectoryURL
        return try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.nameKey, .contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "md" }
    }

    private static func readNote(at url: URL) async throws -> Note? {
        await waitForDownload(of: url)
        guard
            let content = try? String(contentsOf: url, encoding: .utf8),
            let parsed = FrontmatterParser.parse(content)
        else { return nil }

        let filename = url.deletingPathExtension().lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modifiedAt = resourceValues?.contentModificationDate ?? .distantPast
        let createdAt = resourceValues?.creationDate ?? .distantPast
        return Note(
            id: parsed.uid,
            filename: filename,
            tags: parsed.tags,
            body: parsed.body,
            fileURL: url,
            isBookmarked: parsed.bookmarked,
            modifiedAt: modifiedAt,
            createdAt: createdAt
        )
    }

    private static func readNoteMetadata(at url: URL) async throws -> NoteMetadata? {
        await waitForDownload(of: url)
        guard
            let content = try? String(contentsOf: url, encoding: .utf8),
            let parsed = FrontmatterParser.parse(content)
        else { return nil }

        let filename = url.deletingPathExtension().lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modifiedAt = resourceValues?.contentModificationDate ?? .distantPast
        let createdAt = resourceValues?.creationDate ?? .distantPast
        return NoteMetadata(
            id: parsed.uid,
            filename: filename,
            tags: parsed.tags,
            fileURL: url,
            isBookmarked: parsed.bookmarked,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            preview: NoteMetadata.makePreview(from: parsed.body)
        )
    }

    /// No-op for local files and already-downloaded iCloud items. For an undownloaded
    /// ubiquitous item, triggers the download and polls its status instead of letting
    /// `String(contentsOf:)` block on an implicit download — each call runs in its own
    /// task, so many files download in parallel rather than one network round-trip at a time.
    private static func waitForDownload(of url: URL) async {
        guard
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
            status == .notDownloaded
        else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<300 { // ~30s cap per file; falls through to a best-effort read after that
            try? await Task.sleep(for: .milliseconds(100))
            let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if current != .notDownloaded { return }
        }
    }

    func saveNote(_ note: Note) throws {
        let content = FrontmatterParser.serialize(uid: note.id, tags: note.tags, isBookmarked: note.isBookmarked, body: note.body)
        try content.write(to: note.fileURL, atomically: true, encoding: .utf8)
    }

    /// Creates a new note file, appending a numeric suffix to avoid name collisions.
    func createNote(baseName: String = "New Note") throws -> Note {
        let dir = Self.notesDirectoryURL
        var filename = baseName
        var url = dir.appendingPathComponent("\(filename).md")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            filename = "\(baseName) \(counter)"
            url = dir.appendingPathComponent("\(filename).md")
            counter += 1
        }
        let note = Note(id: UUID(), filename: filename, tags: [], body: "", fileURL: url)
        try saveNote(note)
        return note
    }

    /// Rewrites just the `bookmarked` frontmatter flag, re-reading the file to preserve its
    /// current body/tags without requiring the caller to hold a full `Note`.
    func setBookmarked(_ isBookmarked: Bool, at fileURL: URL) throws {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        guard let parsed = FrontmatterParser.parse(content) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let newContent = FrontmatterParser.serialize(
            uid: parsed.uid, tags: parsed.tags, isBookmarked: isBookmarked, body: parsed.body
        )
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func deleteNote(_ metadata: NoteMetadata) throws {
        try FileManager.default.trashItem(at: metadata.fileURL, resultingItemURL: nil)
    }

    /// Renames the note file on disk and returns updated metadata.
    func renameNote(_ metadata: NoteMetadata, to newName: String) throws -> NoteMetadata {
        let newURL = metadata.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(newName).md")
        try FileManager.default.moveItem(at: metadata.fileURL, to: newURL)
        var updated = metadata
        updated.filename = newName
        updated.fileURL = newURL
        return updated
    }

    // MARK: - Private

    private static let customBookmarkKey = "customNotesDirectoryBookmark"
    private static var activeCustomURL: URL?

    // `.withSecurityScope` bookmarks are a macOS-only concept (iOS apps are always
    // sandboxed to their container, so plain bookmarks are sufficient there).
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return .withSecurityScope
        #else
        return []
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return .withSecurityScope
        #else
        return []
        #endif
    }

    private static func resolveCustomNotesDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: customBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if isStale { try? setCustomNotesDirectory(url) }
        activeCustomURL = url
        return url
    }

    private static func icloudNotesURL() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: nil
        ) else { return nil }
        let url = container.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func localFallbackURL() -> URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("MCP Notes")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
