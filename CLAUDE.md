# CLAUDE.md

## Build & Test

Open `mcpnotes-mac.xcodeproj` in Xcode 26+. All commands below use `xcodebuild`.

> **File system sync**: the project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+). Any new Swift file placed inside a target's source folder is automatically included in the build — no changes to `project.pbxproj` needed.

```bash
# Build main app
xcodebuild -project mcpnotes-mac.xcodeproj -scheme mcpnotes-mac -destination 'platform=macOS' build

# Run unit tests (Swift Testing)
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-macTests -destination 'platform=macOS'

# Run MCP server tests
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-serverTests -destination 'platform=macOS'

# Run a single test by name
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-macTests \
  -destination 'platform=macOS' -only-testing:mcpnotes-macTests/MyTestSuite/myTestMethod

# Run UI tests
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-macUITests -destination 'platform=macOS'
```

## Architecture

MVVM with strict layer separation: **Views → ViewModels → Models/Services**. No reverse dependencies.

### Module structure

The project has three targets that share code via a framework:

- **`mcpnotes-core`** — shared framework (`import MCPNotesCore`). Contains only truly platform-agnostic types: `Note`, `SidebarMode`, `FileServicing` protocol, `FrontmatterParser`, markdown utilities (`MarkdownToken`, `MarkdownPatterns`, `MarkdownListContinuation`), `NoteFilenameValidator`, `EditorViewModel`. All public.
- **`mcpnotes-mac`** — main SwiftUI app. Imports `MCPNotesCore`. Contains all Mac-specific code: `NoteStore`, `FileService`, `NoteIndexer`/`NoteIndexing`/`IndexDatabase`, `MarkdownHighlighter`, `MarkdownTextView`, all Views.
- **`mcpnotes-server`** — MCP server executable. Does **not** import `MCPNotesCore`; bundles its own local copies of `Note` and `FrontmatterParser`.

### Data flow

`NoteStore` (injected as `@Environment`) is the single source of truth for all notes. Views read from it; `NoteEditorView` writes back through `NoteStore.updateNote(_:)` after a 1-second debounce managed by `EditorViewModel`.

```
ContentView (NavigationSplitView)
├── SidebarView           ← reads NoteStore, drives selectedNoteID
│   └── NoteListItemView  ← single row in note list
└── NoteEditorView        ← owns EditorViewModel, writes to NoteStore on autosave
    ├── FrontmatterView   ← editable filename (rename + wikilink cascade), editable tags, read-only uid
    │   └── TagsEditorView
    └── MarkdownEditorView

SettingsView             ← opened as a separate window (openWindow)
├── RAGSettingsView      ← RAG toggle + indexer status (Views/Settings/RAGSettingsView.swift)
├── MCPSettingsView      ← MCP config snippet + copy button (Views/Settings/MCPSettingsView.swift)
├── StorageSettingsView  ← notes folder picker, iCloud sync status (Views/Settings/StorageSettingsView.swift)
└── ImportSettingsView   ← Markdown folder import + Apple Notes direct import (Views/Settings/ImportSettingsView.swift)

WikilinkGraphView        ← separate Window scene ("wikilink-graph")
└── GraphSKViewRepresentable  ← NSViewRepresentable
    ├── GraphSKView      ← SKView subclass; restarts SpriteKit display link on reopen
    └── GraphSKScene     ← force-directed graph simulation (repulsion + spring + damping)
```

### MCP server

Separate executable target `mcpnotes-server` in the same Xcode project. The app launches it via `Process` and communicates over `StdioTransport` (stdio MCP protocol). The server is a stateless reader/writer — it accesses the same notes directory and RAG index that the main app writes. It does **not** depend on `mcpnotes-core`; it bundles its own private copies of `Note` and `FrontmatterParser`.

Tools exposed: `list_notes`, `list_notes_by_tag`, `list_tags`, `find_note`, `search_notes`, `get_note`, `update_note`, `create_note`, `rag_search`, `get_note_links`.

### Note file format

Every note is a flat `.md` file with a mandatory YAML frontmatter block:

```
---
uid: <UUID>
tags: [tag1, tag2]
bookmarked: true        ← optional; omitted when false
---

Markdown body…
```

`FrontmatterParser` handles parsing and serialization. `FileService` handles all disk I/O for regular note operations; never bypass it in normal app code. Exception: `ImportSettingsView` writes imported files directly to `FileService.notesDirectoryURL` (using `String.write(to:atomically:encoding:)`) because imported notes are new files, not updates to existing ones tracked by the store.

### Key types

| Type | Role |
|---|---|
| `NoteStore` | `@Observable` class in `mcpnotes-mac`. Indexing uses `noteIndexQueue` processed by `indexWorkerTask` via `enqueueNotes(_:)` — no concurrent `indexAll`, progressive indexing; `createNote`/`updateNote`/`renameNote` call `indexNote` directly. Browser-style navigation: `canNavigateBack`/`canNavigateForward`. External changes via `scheduleExternalReload`/`reloadExternalChanges`. |
| `SidebarMode` | `enum` in `mcpnotes-core`. In `.search` mode results split into: **Title** (filename match), **Content** (body/tag match), **Related** (RAG semantic matches with score %). |
| `EditorViewModel` | `@Observable` class in `mcpnotes-core`. One instance per `NoteEditorView`. Owns autosave `Task`. |
| `FileService` | `struct` in `mcpnotes-mac` conforming to `FileServicing`. Uses iCloud Drive, security-scoped bookmarks for custom directories, falls back to Application Support. |
| `NoteFilenameValidator` | `struct` in `mcpnotes-core`. Allowlist: Unicode letters, digits, space, hyphen, underscore, period. `maxLength = 200`. Returns `ValidationResult`: `.valid`, `.empty`, `.tooLong`, `.forbiddenCharacter`. |
| `NoteIndexer` | `actor` in `mcpnotes-mac`. Hybrid search: USearch vectors (multilingual-e5-small, 384-dim cosine) + SQLite FTS5 BM25. MD5-based incremental sync. `pending_removes`: `removeNote()` writes here synchronously; `loadFromDisk()` applies them on cold start + runs six integrity checks (returns `true` → full re-index needed); `saveToDisk()` clears them — idempotent across crashes. Files: `mcpnotes-mac/NoteIndexer/`. |
| `IndexDatabase` | Private SQLite wrapper. Tables: chunk→key mappings, MD5 hashes, FTS5 full-text, tag index, note metadata, `pending_removes`. Used only by `NoteIndexer`. |
| `GraphSKView` | `SKView` subclass. Observes `NSWindow.didChangeOcclusionStateNotification` to restart SpriteKit's display link on reopen (SpriteKit stops it without going through `isPaused`). |
| `GraphSKScene` | `SKScene` subclass. Force-directed: O(n²) repulsion, spring edges, center gravity, `simAlpha` damping. |
| `NoteListItemView` | Sidebar row. `searchQuery: String?` — replaces body preview with ±40-char snippet, match bolded. `score: Float?` — semantic similarity % (RAG results). |
| `MarkdownHighlighter` | AppKit-dependent `struct`. Applies TextKit 2 attributes for CommonMark + GFM; used by `MarkdownTextViewRepresentable.Coordinator`. |
| `MarkdownTextView` | `NSTextView` subclass in `MarkdownTextViewRepresentable.swift`. Features: pointing-hand cursor on links; single-click `[[wikilink]]`/`[text](url)` navigation; list auto-continuation on Enter; numbered list renumbering; image paste → saves file, inserts `![](filename)`. |
| `TextFormatProxy` | Routes toolbar formatting to the active `NSTextView` without coupling `NoteEditorView` to `MarkdownTextViewRepresentable`. Cursor-aware, handles multi-line selections. |
| `ImportSettingsView` | Two flows: (1) Markdown folder via `NSOpenPanel`; (2) Apple Notes via `NSAppleScript` (HTML→Markdown via regex). Both write to `FileService.notesDirectoryURL`. |

### Directory watching

`NoteStore` watches the notes directory via `DispatchSource.makeFileSystemObjectSource` (events: `.write`, `.link`). Any external change (MCP server write, iCloud sync) triggers a 1 s debounced `reloadExternalChanges()` that diffs the current in-memory notes against fresh disk state, then: removes deleted notes from the index directly (`removeNote`), and enqueues only added/changed notes via `enqueueNotes(_:)`. The per-note queue worker calls `indexNoteIfChanged` — unchanged notes are skipped without ML inference.

### Apple Events from sandbox (macOS 26)

On macOS 26, `automation.apple-events` alone fails without a provisioning profile (error -600). `temporary-exception.apple-events` with `["com.apple.Notes", "com.apple.finder"]` works without a profile and correctly triggers the TCC dialog — both keys are required in `mcpnotes-mac.entitlements`.

`NSAppleScript` must run on the main thread. Target Notes by bundle ID (`tell application id "com.apple.Notes"`), not by name.

## Swift conventions

- No force-unwrap (`!`) outside of tests.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` on app + core targets — all types implicitly `@MainActor`. File I/O in `NoteStore` uses `Task { }` (suspends on main actor).
- Public types in `mcpnotes-core` get DocC `///` comments.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest — except UI tests.
- Use `@Suite` to group tests. One suite per component.
- `NoteIndexerIntegrationTests.swift` downloads the ML model (~115 MB); requires `.timeLimit(.minutes(5))`.
- `NoteStoreTests.swift` uses `MockFileService` and `MockNoteIndexer` (same file, no disk I/O). `MockNoteIndexer` tracks calls via `indexNoteCalledWith`, `indexNoteIfChangedCalledWith`, `removeNoteCalledWith`, `indexAllCalledWith`.
