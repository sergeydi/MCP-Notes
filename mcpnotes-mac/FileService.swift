import Foundation
import MCPNotesCore

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
            options: .withSecurityScope,
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

    func loadAllNotes() throws -> [Note] {
        let dir = Self.notesDirectoryURL
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.nameKey, .contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "md" }

        return files.compactMap { url -> Note? in
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
        }.sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
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

    func deleteNote(_ note: Note) throws {
        try FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
    }

    /// Renames the note file on disk and returns an updated `Note` value.
    func renameNote(_ note: Note, to newName: String) throws -> Note {
        let newURL = note.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(newName).md")
        try FileManager.default.moveItem(at: note.fileURL, to: newURL)
        var updated = note
        updated.filename = newName
        updated.fileURL = newURL
        return updated
    }

    // MARK: - Private

    private static let customBookmarkKey = "customNotesDirectoryBookmark"
    private static var activeCustomURL: URL?

    private static func resolveCustomNotesDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: customBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
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
