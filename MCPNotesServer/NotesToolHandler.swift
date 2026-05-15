import Foundation
import MCP

enum NotesToolHandler {

    // MARK: - Tool definitions

    static let tools: [Tool] = [
        Tool(
            name: "list_tags",
            description: "List all tags used across all notes, with the count of notes per tag.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "list_notes_by_tag",
            description: "List all notes that have a specific tag.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "tag": ["type": "string", "description": "Tag name (exact match)"]
                ],
                "required": ["tag"]
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "list_notes",
            description: "List all notes. Returns filename and uid for every note.",
            inputSchema: [
                "type": "object",
                "properties": [:]
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "search_notes",
            description: "Search notes by keyword in filename, body, and tags. Returns matching notes sorted by filename.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Keyword to search for (case-insensitive)"
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of results to return (default 10)"
                    ]
                ],
                "required": ["query"]
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_note",
            description: "Get the full content of a note by its UID.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "uid": [
                        "type": "string",
                        "description": "Note UID (UUID string from search_notes results)"
                    ]
                ],
                "required": ["uid"]
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "update_note",
            description: "Replace the markdown body of a note. Frontmatter (uid, tags) is preserved.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "uid": [
                        "type": "string",
                        "description": "Note UID (UUID string)"
                    ],
                    "body": [
                        "type": "string",
                        "description": "New markdown body content"
                    ]
                ],
                "required": ["uid", "body"]
            ],
            annotations: Tool.Annotations(destructiveHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "find_note",
            description: "Find notes by filename (title). Returns uid and filename for all matches.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Filename to search for (case-insensitive substring match)"
                    ]
                ],
                "required": ["title"]
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "rag_search",
            description: "Hybrid BM25+vector semantic search (evaluation mode). Results show vector rank (v:N) and BM25 rank (h:N) for comparison. Sorted by combined hybrid score.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Natural-language query to search for semantically similar notes"
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of results to return (default 5)"
                    ]
                ],
                "required": ["query"]
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        )
    ]

    // MARK: - Dispatch

    static func call(_ params: CallTool.Parameters, service: NotesService, searcher: any RAGSearching) async throws -> CallTool.Result {
        switch params.name {
        case "list_tags":
            return await listTags(service: service, searcher: searcher)
        case "list_notes_by_tag":
            return await listNotesByTag(params.arguments ?? [:], service: service, searcher: searcher)
        case "list_notes":
            return listNotes(service: service)
        case "search_notes":
            return searchNotes(params.arguments ?? [:], service: service)
        case "get_note":
            return getNote(params.arguments ?? [:], service: service)
        case "update_note":
            return updateNote(params.arguments ?? [:], service: service)
        case "find_note":
            return findNote(params.arguments ?? [:], service: service)
        case "rag_search":
            return try await ragSearch(params.arguments ?? [:], service: service, searcher: searcher)
        default:
            throw MCPError.methodNotFound("Unknown tool: \(params.name)")
        }
    }

    // MARK: - Tool implementations

    private static func listTags(service: NotesService, searcher: any RAGSearching) async -> CallTool.Result {
        if await searcher.isReady {
            let tags = await searcher.allTags()
            guard !tags.isEmpty else { return text("No tags found.") }
            let lines = tags.map { "\($0.tag) (\($0.count))" }
            return text(lines.joined(separator: "\n"))
        }
        let notes = service.loadAll()
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags { counts[tag, default: 0] += 1 }
        }
        guard !counts.isEmpty else { return text("No tags found.") }
        let lines = counts.sorted { $0.key < $1.key }
            .map { "\($0.key) (\($0.value))" }
        return text(lines.joined(separator: "\n"))
    }

    private static func listNotesByTag(_ args: [String: Value], service: NotesService, searcher: any RAGSearching) async -> CallTool.Result {
        guard let tag = args["tag"]?.stringValue else {
            return error("Missing required argument: tag")
        }
        if await searcher.isReady {
            let matches = await searcher.notes(forTag: tag)
            guard !matches.isEmpty else { return text("No notes found with tag '\(tag)'.") }
            let lines = matches.map { "uid:\($0.uuid.uuidString)  \($0.filename)" }
            return text(lines.joined(separator: "\n"))
        }
        let matches = service.loadAll()
            .filter { $0.tags.contains(tag) }
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
        guard !matches.isEmpty else { return text("No notes found with tag '\(tag)'.") }
        let lines = matches.map { "uid:\($0.id.uuidString)  \($0.filename)" }
        return text(lines.joined(separator: "\n"))
    }

    private static func listNotes(service: NotesService) -> CallTool.Result {
        let notes = service.loadAll()
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
        guard !notes.isEmpty else {
            return text("No notes found.")
        }
        let lines = notes.map { "uid:\($0.id.uuidString)  \($0.filename)" }
        return text(lines.joined(separator: "\n"))
    }

    private static func searchNotes(_ args: [String: Value], service: NotesService) -> CallTool.Result {
        guard let query = args["query"]?.stringValue else {
            return error("Missing required argument: query")
        }
        let limit = args["limit"].flatMap { Int($0) } ?? 10
        let lowercased = query.lowercased()

        let matches = service.loadAll()
            .filter { note in
                note.filename.lowercased().contains(lowercased)
                    || note.body.lowercased().contains(lowercased)
                    || note.tags.contains { $0.lowercased().contains(lowercased) }
            }
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
            .prefix(limit)

        guard !matches.isEmpty else {
            return text("No notes found matching '\(query)'.")
        }

        let lines = matches.map { note -> String in
            let tags = note.tags.isEmpty ? "" : " [tags: \(note.tags.joined(separator: ", "))]"
            return "uid:\(note.id.uuidString)  \(note.filename)\(tags)"
        }
        return text(lines.joined(separator: "\n"))
    }

    private static func getNote(_ args: [String: Value], service: NotesService) -> CallTool.Result {
        guard
            let uidString = args["uid"]?.stringValue,
            let uid = UUID(uuidString: uidString)
        else {
            return error("Missing or invalid argument: uid")
        }
        guard let note = service.note(uid: uid) else {
            return error("Note not found: \(args["uid"]?.stringValue ?? "(nil)")")
        }
        let tagLine = note.tags.isEmpty ? "tags: (none)" : "tags: \(note.tags.joined(separator: ", "))"
        let output = """
        # \(note.filename)
        uid: \(note.id.uuidString)
        \(tagLine)

        \(note.body)
        """
        return text(output)
    }

    private static func updateNote(_ args: [String: Value], service: NotesService) -> CallTool.Result {
        guard
            let uidString = args["uid"]?.stringValue,
            let uid = UUID(uuidString: uidString)
        else {
            return error("Missing or invalid argument: uid")
        }
        guard let body = args["body"]?.stringValue else {
            return error("Missing required argument: body")
        }
        do {
            try service.updateNote(uid: uid, body: body)
            return text("Note updated successfully.")
        } catch {
            return Self.error("Failed to update note: \(error)")
        }
    }

    private static func findNote(_ args: [String: Value], service: NotesService) -> CallTool.Result {
        guard let title = args["title"]?.stringValue else {
            return error("Missing required argument: title")
        }
        let lowercased = title.lowercased()
        let matches = service.loadAll()
            .filter { $0.filename.lowercased().contains(lowercased) }
            .sorted { $0.filename.localizedCompare($1.filename) == .orderedAscending }
        guard !matches.isEmpty else {
            return text("No notes found with title matching '\(title)'.")
        }
        let lines = matches.map { "uid:\($0.id.uuidString)  \($0.filename)" }
        return text(lines.joined(separator: "\n"))
    }

    private static func ragSearch(_ args: [String: Value], service: NotesService, searcher: any RAGSearching) async throws -> CallTool.Result {
        guard let query = args["query"]?.stringValue else {
            return error("Missing required argument: query")
        }
        guard await searcher.isReady else {
            return error("RAG index is not available. Enable RAG in the app and wait for indexing to complete.")
        }
        let limit = args["limit"].flatMap { Int($0) } ?? 5
        let ranked = try await searcher.searchRankedHybrid(query: query, limit: limit)
        guard !ranked.isEmpty else {
            return text("No semantically similar notes found for '\(query)'.")
        }
        let allNotes = service.loadAll()
        let noteMap = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })
        let lines = ranked.compactMap { hit -> String? in
            guard let note = noteMap[hit.uuid] else { return nil }
            let score = String(format: "%.3f", hit.vectorScore)
            let hRank = hit.bm25Rank.map { "h:\($0)" } ?? "h:-"
            let tags = note.tags.isEmpty ? "" : "  [tags: \(note.tags.joined(separator: ", "))]"
            return "v:\(hit.vectorRank) \(hRank)  score:\(score)  uid:\(note.id.uuidString)  \(note.filename)\(tags)"
        }
        guard !lines.isEmpty else {
            return text("No notes found matching RAG results.")
        }
        return text(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func text(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)])
    }

    private static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
