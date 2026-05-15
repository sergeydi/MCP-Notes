import Foundation

/// Provides read/write access to notes on disk for the MCP server process.
///
/// Notes directory resolution order:
///   1. MCPNOTES_DIR environment variable (set by the host app when launching the server)
///   2. iCloud Drive container Documents folder
///   3. Local Application Support fallback (development / no iCloud)
struct NotesService: Sendable {

    let directory: URL

    init(directory: URL = Self.notesDirectoryURL) {
        self.directory = directory
    }

    static var notesDirectoryURL: URL {
        if let envPath = ProcessInfo.processInfo.environment["MCPNOTES_DIR"],
           FileManager.default.fileExists(atPath: envPath)
        {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        if let icloud = icloudNotesURL() { return icloud }
        // Check the sandboxed app container — the app writes here when running in App Sandbox
        let sandboxPath = sandboxContainerNotesURL()
        if FileManager.default.fileExists(atPath: sandboxPath.path) {
            return sandboxPath
        }
        return localFallbackURL()
    }

    private static func sandboxContainerNotesURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers/mcp-notes/Data/Library/Application Support/MCP Notes/Notes")
    }

    func loadAll() -> [Note] {
        let dir = directory
        fputs("[mcpnotes] notes dir: \(dir.path)\n", stderr)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter({ $0.pathExtension == "md" }) else {
            fputs("[mcpnotes] contentsOfDirectory failed at: \(dir.path)\n", stderr)
            return []
        }
        fputs("[mcpnotes] found \(files.count) notes\n", stderr)

        return files.compactMap { url -> Note? in
            guard
                let content = try? String(contentsOf: url, encoding: .utf8),
                let parsed = FrontmatterParser.parse(content)
            else { return nil }
            let filename = url.deletingPathExtension().lastPathComponent
            return Note(
                id: parsed.uid,
                filename: filename,
                tags: parsed.tags,
                body: parsed.body,
                fileURL: url
            )
        }
    }

    func note(uid: UUID) -> Note? {
        loadAll().first { $0.id == uid }
    }

    func updateNote(uid: UUID, body: String) throws {
        guard let existing = note(uid: uid) else {
            throw NotesServiceError.notFound(uid)
        }
        let content = FrontmatterParser.serialize(uid: existing.id, tags: existing.tags, body: body)
        try content.write(to: existing.fileURL, atomically: true, encoding: .utf8)
    }

    func createNote(title: String, tags: [String] = [], body: String = "") throws -> Note {
        var filename = title.isEmpty ? "New Note" : title
        var url = directory.appending(path: "\(filename).md")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            filename = "\(title) \(counter)"
            url = directory.appending(path: "\(filename).md")
            counter += 1
        }
        let uid = UUID()
        let content = FrontmatterParser.serialize(uid: uid, tags: tags, body: body)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return Note(id: uid, filename: filename, tags: tags, body: body, fileURL: url)
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

enum NotesServiceError: Error, CustomStringConvertible {
    case notFound(UUID)

    var description: String {
        switch self {
        case .notFound(let uid): return "Note not found: \(uid.uuidString)"
        }
    }
}
