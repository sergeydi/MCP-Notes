import Foundation

protocol FileServicing {
    func loadAllNotes() throws -> [Note]
    func saveNote(_ note: Note) throws
    func createNote(baseName: String) throws -> Note
    func deleteNote(_ note: Note) throws
    func renameNote(_ note: Note, to newName: String) throws -> Note
}

/// Handles reading and writing note files from the notes directory.
///
/// Notes are stored as flat `.md` files — no subdirectories. The preferred
/// location is the app's iCloud Drive container; the local Application Support
/// directory is used as a fallback during development without iCloud configured.
struct FileService: FileServicing {

    /// Root directory where all note files are stored.
    static var notesDirectoryURL: URL {
        if let icloudURL = icloudNotesURL() {
            return icloudURL
        }
        return localFallbackURL()
    }

    func loadAllNotes() throws -> [Note] {
        let dir = Self.notesDirectoryURL
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.nameKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "md" }

        return files.compactMap { url -> Note? in
            guard
                let content = try? String(contentsOf: url, encoding: .utf8),
                let parsed = FrontmatterParser.parse(content)
            else { return nil }

            let filename = url.deletingPathExtension().lastPathComponent
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Note(
                id: parsed.uid,
                filename: filename,
                tags: parsed.tags,
                body: parsed.body,
                fileURL: url,
                isBookmarked: parsed.bookmarked,
                modifiedAt: modifiedAt
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

    private static func icloudNotesURL() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: nil
        ) else { return nil }
        let url = container.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func localFallbackURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = appSupport.appendingPathComponent("MCP Notes/Notes")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
