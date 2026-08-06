# MCP Notes

A native macOS Markdown note-taking app with built-in semantic search and an [MCP](https://modelcontextprotocol.io) server — so AI tools like Claude can read, search, and edit your notes directly.

[![Download on the App Store](https://upload.wikimedia.org/wikipedia/commons/0/0e/Download_on_the_Mac_App_Store_Badge_US-UK_RGB_wht.svg)](https://apps.apple.com/app/mcp-notes/id6762989069) [![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/mcp-notes/id6762989069)

[🌐 Official Website](https://mcp-notes.com)

<img width="1600" height="1200" alt="ezgif-59b0a59764651c27" src="https://github.com/user-attachments/assets/eefa8b6c-22bc-4c17-87f9-adecf78764ac" />


## Features

- **Plain Markdown files** — every note is a `.md` file with a YAML frontmatter block (`uid`, `tags`). No proprietary format, no lock-in.
- **iCloud sync** — notes live in iCloud Drive and sync across your Mac devices automatically.
- **Wikilinks** — `[[Note Name]]` links between notes with one-click navigation and a force-directed graph view.
- **Semantic search (RAG)** — powered by [multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) embeddings + USearch vectors + SQLite FTS5 BM25. Works across languages.
- **MCP server** — exposes your notes as MCP tools (`list_notes`, `search_notes`, `get_note`, `update_note`, `create_note`, `rag_search`, …) over stdio. Works with Claude Code and other MCP clients.
- **Markdown editor** — syntax highlighting, list auto-continuation, numbered list renumbering, image paste support.
- **Import** — import a folder of Markdown files or import directly from Apple Notes.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26+ (to build from source)

## MCP Server Setup

1. Open **Settings → MCP** in the app and copy the ready-made JSON snippet.
2. Paste it into your Claude Code (or other MCP client) configuration.
3. Enable RAG in **Settings → RAG** — this downloads the embedding model (~115 MB) and starts the MCP server process.

The server runs as a subprocess of the app and communicates over stdio. It accesses the same notes directory and RAG index as the main app.

### Available MCP tools

| Tool | Description |
|---|---|
| `list_notes` | List all notes (uid, title, tags) |
| `list_notes_by_tag` | Filter notes by tag |
| `list_tags` | List all tags |
| `find_note` | Find a note by title |
| `search_notes` | Full-text + semantic search |
| `get_note` | Get full note content by title or uid |
| `update_note` | Update content, tags, or rename a note |
| `create_note` | Create a new note |
| `rag_search` | Semantic-only vector search |
| `get_note_links` | Get wikilinks for a note |

## Note Format

```markdown
---
uid: 550E8400-E29B-41D4-A716-446655440000
tags: [swift, ideas]
bookmarked: true
---

Your Markdown body here…
```

## Tech Stack

| Component | Library |
|---|---|
| Embeddings | [swift-embeddings](https://github.com/jkrukowski/swift-embeddings) |
| Vector store | [USearch](https://github.com/unum-cloud/USearch) |
| MCP protocol | [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) |
| Full-text search | SQLite FTS5 |
| UI | SwiftUI + AppKit (NSTextView) |
| Language | Swift 6 |

## License

MIT
