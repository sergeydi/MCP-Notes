# CLAUDE.md

## Build & Test

Open `mcpnotes-mac.xcodeproj` in Xcode 26+. All commands below use `xcodebuild`. `mcpnotes-app` targets both macOS and iOS (iPhone and iPad — see [iOS support](#ios-support)); `mcpnotes-server`/`mcpnotes-embeddings` remain macOS-only.

> **File system sync**: the project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+). Any new Swift file placed inside a target's source folder is automatically included in the build for **both** macOS and iOS — no changes to `project.pbxproj` needed, *unless* the file must be excluded from one platform (see the platform-filter pattern below).

```bash
# Build main app (macOS)
xcodebuild -project mcpnotes-mac.xcodeproj -scheme mcpnotes-app -destination 'platform=macOS' build

# Build main app (iOS Simulator — universal, runs on iPhone and iPad)
xcodebuild -project mcpnotes-mac.xcodeproj -scheme mcpnotes-app -destination 'generic/platform=iOS Simulator' build

# Run unit tests (Swift Testing) — macOS
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-appTests -destination 'platform=macOS'

# Run unit tests — iOS Simulator (any iPhone/iPad destination works; iPad shown here)
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-appTests -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'

# Run MCP server tests
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-serverTests -destination 'platform=macOS'

# Run a single test by name
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-appTests \
  -destination 'platform=macOS' -only-testing:mcpnotes-appTests/MyTestSuite/myTestMethod

# Run UI tests
xcodebuild test -project mcpnotes-mac.xcodeproj -scheme mcpnotes-appUITests -destination 'platform=macOS'

# Install + launch on a connected physical iPhone or iPad
# 1. List paired devices — if more than one iOS device shows up, ask the user which one (don't guess)
xcrun devicectl list devices
# 2. Build for that specific device (not generic/platform=iOS — a concrete id signs with the right provisioning profile)
xcodebuild -project mcpnotes-mac.xcodeproj -scheme mcpnotes-app -destination 'id=<device-id>' build
# 3. Install the .app from DerivedData. The glob must NOT be double-quoted (quoting disables
#    shell expansion, so the literal "mcpnotes-mac-*" path segment fails) — resolve it into a
#    variable first, since the DerivedData hash suffix is stable per checkout but unknown upfront.
APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -iname 'mcpnotes-mac-*' | head -1)/Build/Products/Debug-iphoneos/MCP Notes.app"
xcrun devicectl device install app --device <device-id> "$APP_PATH"
# 4. Launch by bundle id (not app name)
xcrun devicectl device process launch --device <device-id> mcp-notes
```

## Architecture

MVVM with strict layer separation: **Views → ViewModels → Models/Services**. No reverse dependencies.

### Module structure

The project has three main code targets:

- **`mcpnotes-app`** — main SwiftUI app (target/module name `mcpnotes_app`), builds for **macOS and iOS (iPhone and iPad)**. Contains everything: `Note`, `SidebarMode`, `FileServicing` protocol, `FrontmatterParser`, markdown utilities (`MarkdownToken`, `MarkdownPatterns`, `MarkdownListContinuation`), `NoteFilenameValidator`, `EditorViewModel`, `NoteStore`, `FileService`, `NoteIndexer`/`NoteIndexing`/`IndexDatabase`, `MarkdownHighlighter`, `MarkdownTextView`, all Views. There is no separate shared framework — everything lives in this one target. See [iOS support](#ios-support) for what's macOS-only.
- **`mcpnotes-embeddings`** — XPC Service. Runs in a separate process inside `Contents/XPCServices/`. Loads multilingual-e5-small via the `Embeddings` package and exposes `EmbeddingXPCProtocol`. The main app connects on first embed call and disconnects after 60 s of idle (`exit(0)` on invalidation), so CoreML/Metal memory is fully released by the OS between indexing sessions.
- **`mcpnotes-server`** — MCP server executable. Does **not** depend on `mcpnotes-app`; it bundles its own private copies of `Note` and `FrontmatterParser`.

### Data flow

`NoteStore` (injected as `@Environment`) is the single source of truth for all notes. Views read from it; `NoteEditorView` writes back through `NoteStore.updateNote(_:)` after a 3-second debounce managed by `EditorViewModel`.

```
ContentView (NavigationSplitView)
├── SidebarView           ← reads NoteStore, drives selectedNoteID
│   └── NoteListItemView  ← single row in note list
└── NoteEditorView        ← owns EditorViewModel, writes to NoteStore on autosave
    └── MarkdownEditorView
        └── MarkdownTextViewRepresentable  ← hosts FrontmatterView as a header (see below)
            └── FrontmatterView   ← editable filename (rename + wikilink cascade), editable tags, read-only uid
                ├── FilenameEditorView ← platform-split (+macOS/+iOS)
                └── TagsEditorView

SettingsView (macOS only) ← opened as a separate window (openWindow)
├── RAGSettingsView      ← RAG toggle + indexer status (Views/Settings/RAGSettingsView.swift)
├── MCPSettingsView      ← MCP config snippet + copy button (Views/Settings/MCPSettingsView.swift)
├── StorageSettingsView  ← notes folder picker, iCloud sync status (Views/Settings/StorageSettingsView.swift)
└── ImportSettingsView   ← Markdown folder import + Apple Notes direct import (Views/Settings/ImportSettingsView.swift)

WikilinkGraphView (macOS only) ← separate Window scene ("wikilink-graph")
└── GraphSKViewRepresentable  ← NSViewRepresentable
    ├── GraphSKView      ← SKView subclass; restarts SpriteKit display link on reopen
    └── GraphSKScene     ← force-directed graph simulation (repulsion + spring + damping)
```

`FrontmatterView` is not a sibling pane next to the markdown body — it's passed into `MarkdownEditorView`/`MarkdownTextViewRepresentable` as a `header: FrontmatterView` parameter and hosted as an `NSHostingView`/`UIHostingView` subview *inside* the text view's document (pinned to its top/leading/width edges). The text container reserves space for it via an exclusion path (`headerHeight`, updated live off the hosting view's frame-change notifications), so the filename/tags header scrolls together with the note body in a single `NSTextView`/`UITextView` scroll view rather than as a separate SwiftUI view above it.

### iOS support

`mcpnotes-app` builds for iOS too (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, `TARGETED_DEVICE_FAMILY = "1,2"` — iPhone and iPad). There is no iPhone/iPad idiom branching anywhere yet (no `userInterfaceIdiom`/`horizontalSizeClass` usage) — the same iOS layout runs on both, so a phone-specific compact layout is a known gap to watch for as usage grows. RAG, Embeddings, MCP config, the Settings window, and the Wikilink Graph window are all **macOS-only**; iOS search is title/content match only (no semantic "Related" section — there's no UI to ever enable `ragEnabled` on iOS, so it never activates).

**Platform filtering** is done per-file via `PBXFileSystemSynchronizedBuildFileExceptionSet.platformFiltersByRelativePath` in `project.pbxproj` (`(macos, )` or `(ios, )`), *not* `#if os()` — this keeps the excluded files out of the other platform's build entirely rather than compiling them to nothing. Currently macOS-only: `NoteIndexer/{EmbeddingXPCProtocol,IndexDatabase,NoteEmbedding,NoteIndexer,XPCNoteEmbedder}.swift`, all of `Views/Settings/`, all of `Views/WikilinkGraph/`, `Views/Editor/MarkdownTextViewRepresentable+macOS.swift`, `Views/Editor/FilenameEditorView+macOS.swift`. iOS-only: `Views/Editor/MarkdownTextViewRepresentable+iOS.swift`, `Views/Editor/FilenameEditorView+iOS.swift`. The same exception mechanism is applied to the `mcpnotes-appTests` target for the indexer/embedding test suites that need the real `NoteIndexer`/`MockNoteEmbedder`.

- **`NoOpNoteIndexer`** (`NoteIndexer/NoOpNoteIndexer.swift`, unfiltered — compiles on both platforms) — no-op `NoteIndexing` actor used on iOS in place of the real `NoteIndexer` (constructed conditionally with `#if os(macOS)` in `mcpnotes_App.swift` / `ContentView.swift`'s `#Preview`).
- **`MarkdownTextViewRepresentable`** — two independent implementations sharing the same struct name/public interface (`text`, `onTextChanged`, `onWikilinkTapped`, `notesDirectoryURL`, `formatProxy`, `header: FrontmatterView`) so `MarkdownEditorView` doesn't need to know which platform it's on: `+macOS.swift` (`NSTextView`) and `+iOS.swift` (`UITextView`) — both now at full feature parity: syntax highlighting, wikilink/link tap navigation, list auto-continuation/renumbering, toolbar formatting, pasted-image insertion, inline `![[filename]]` embed preview, and a code-block copy button. `MarkdownHighlighter` is genuinely cross-platform (AppKit/UIKit typealiases + a `UIColor` extension shimming the AppKit semantic color names).
- **`FilenameEditorView`** — same pattern: two independent implementations sharing the struct name/public interface (`filename`, `draftFilename`, `isEditingFilename`, `isRenamingInProgress`, `wikilinkRenameCount`, `otherFilenames`, `onApplyRename`), used by `FrontmatterView` on both platforms. Both start editing as soon as the cursor is placed in the field (no separate edit button). `+macOS.swift`: Enter applies the rename, Escape or losing focus without Enter reverts the draft. `+iOS.swift`: touch-first — 44pt-minimum Cancel/Apply tap targets (no hardware Escape to rely on) instead of a keyboard shortcut, and the whole filename is selected on focus so retyping doesn't require manual deletion.
- **Entitlements**: `mcpnotes-app-iOS.entitlements` (iCloud keys only) is used on iOS via `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]`/`[sdk=iphonesimulator*]`; macOS keeps the existing `mcpnotes-app-macOS.entitlements` (App Sandbox, Apple Events automation, etc. — none of which apply to iOS).
- **Frameworks**: `Embeddings`/`MCP`/`MLTensorUtils`/`USearch` are excluded from the iOS link via `platformFilters = (macos, );` on their `PBXBuildFile` entries in the Frameworks build phase — confirmed with `otool -L` that they're absent from the iOS binary.
- **Fixed gap**: the embedded `mcpnotes-embeddings.xpc` (Copy Files build phase) and the `mcpnotes-server` executable (Copy Server Executable build phase) used to get copied into iOS app bundles regardless of platform, which App Store Connect rejected on upload ("Unexpected CFBundleExecutable Key... does not contain a bundle executable"). Fixed by adding `platformFilters = (macos, );` to **both** the `PBXBuildFile` entry in each Copy Files phase *and* the corresponding `PBXTargetDependency` (`mcpnotes-embeddings`/`mcpnotes-server` target dependencies on `mcpnotes-app`) — filtering only one of the two isn't enough, since the build file filter alone still leaves the dependency forcing the macOS-only target to build. Verified via `xcodebuild ... -destination 'generic/platform=iOS Simulator'` that the built `.app` has no `XPCServices` folder and no `mcpnotes-server` binary, and via `-destination 'platform=macOS'` that both are still embedded correctly there.
- **`FileService`**: `.withSecurityScope` bookmark options are macOS-only (unavailable on iOS) — `bookmarkCreationOptions`/`bookmarkResolutionOptions` computed properties branch on `#if os(macOS)`, iOS gets `[]` (plain bookmarks; there's no custom-folder picker UI on iOS anyway, so this path is effectively dead there and always falls through to iCloud Drive/local storage).
- **Watch out**: `NoteStore.load()` runs `fileService.loadAllNotes()` inside `Task.detached` rather than directly — resolving the notes directory can call `FileManager.url(forUbiquityContainerIdentifier:)`, which can block for a long time on first access. Doing that synchronously on the main actor during app launch trips iOS's scene-creation watchdog (`0x8BADF00D`, `EXC_CRASH`/`SIGKILL` after ~20s) and kills the app before it ever renders. Keep any future main-actor-isolated work in the launch path off the main thread if it touches iCloud/Foundation APIs that can block.

### Embeddings XPC service

`mcpnotes-embeddings` is a sandboxed XPC Service that lives at `Contents/XPCServices/mcpnotes-embeddings.xpc`. It loads multilingual-e5-small (XLM-RoBERTa, 384-dim) using the `Embeddings` Swift package and exposes `EmbeddingXPCProtocol` over `NSXPCConnection`. The main app (`XPCNoteEmbedder`) connects on first embed call; after 60 s of idle it invalidates the connection, which triggers `exit(0)` in the service — the OS fully reclaims all CoreML/Metal memory (~450 MB). On the next embed call the connection is re-established and the model reloads from the CoreML cache (fast, no re-download).

Key files: `mcpnotes-embeddings/mcpnotes_embeddings.swift`, `mcpnotes-embeddings/main.swift`, `mcpnotes-embeddings/mcpnotes_embeddingsProtocol.swift`. The protocol (`EmbeddingXPCProtocol`) is duplicated in both the service and `mcpnotes-app/NoteIndexer/EmbeddingXPCProtocol.swift` (NSXPCConnection requires `@objc protocol`).

### MCP server

Separate executable target `mcpnotes-server` in the same Xcode project. The app launches it via `Process` and communicates over `StdioTransport` (stdio MCP protocol). The server is a stateless reader/writer — it accesses the same notes directory and RAG index that the main app writes. It does **not** depend on `mcpnotes-app`; it bundles its own private copies of `Note` and `FrontmatterParser`.

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

### Lazy note loading

`NoteStore.notes: [NoteMetadata]` holds metadata (filename/tags/uid/isBookmarked/dates/`preview`) for every note, always. A note's full `body` is loaded from disk on demand via `NoteStore.loadFullNote(_:)` (→ `FileService.loadNote(at:)`) and is expected to be resident for at most one note at a time — the note open in the editor, or transiently inside a loop that reads/checks/discards one note's body before moving to the next.

- **Editor**: `NoteEditorView` takes a `NoteMetadata` and loads the full `Note` in `.task(id: noteMetadata.id)`; since the view's identity is `.id(note.id)` at both call sites (`ContentView`, the standalone-window `WindowGroup(for: UUID.self)`), switching to a different note tears down the whole view (including its `@State EditorViewModel`) rather than reusing it — the old note's body is released as a side effect of normal SwiftUI view lifecycle, not through any explicit cleanup. Autosave (`viewModel.onSave`) looks up the note fresh from `store.notes` by id at save time rather than closing over a captured value, so a rename that lands between edits is reflected in the saved `fileURL`/`filename`.
- **Indexing worker** (`NoteStore.enqueueNotes`/`indexWorkerTask`): the queue holds `[NoteMetadata]`, not `[Note]` — the worker reads each note's body from disk immediately before calling `indexer.indexNoteIfChanged(_:)` and lets it go out of scope right after, so even a full cold-start reindex of a large vault never holds more than one body in memory.
- **Rename wikilink cascade** (`NoteStore.renameNote`): reads/checks/rewrites/saves each candidate note one at a time via `fileService.loadNote(at:)`/`saveNote(_:)` rather than scanning an in-memory array of full notes.
- **Content search** (`SidebarView`'s "Content" section, `NoteStore.searchNoteBodies`): a 300ms-debounced async scan that reads each remaining candidate's body from disk, checks for a match, and discards it — preserves exact substring semantics (rather than switching to the token-based FTS5 index, which would diverge from iOS's plain-scan behavior) while never holding more than one candidate's body at a time.
- **`FileService.loadAllNotes()` is unchanged and still loads every note's full body at once** — kept only for `AppIntents/*` (`SearchNotesIntent`, `NoteEntity`, `AppendToNoteIntent`, ...), which run out-of-process with their own `FileService()` instance, independent of `NoteStore`, and genuinely need every note's body for their own substring search / snippet building.

### Key types

| Type | Role |
|---|---|
| `NoteStore` | `@Observable` class in `mcpnotes-app`. `notes: [NoteMetadata]` — metadata only, always resident for every note; a note's full `body` is loaded from disk on demand (`loadFullNote(_:)`) and expected to be resident for at most one note at a time (see [Lazy note loading](#lazy-note-loading)). Indexing uses `noteIndexQueue: [NoteMetadata]` processed by `indexWorkerTask` via `enqueueNotes(_:)` — the worker reads each note's body from disk immediately before indexing it and discards it right after, so a full cold-start reindex never holds more than one body at a time; no concurrent `indexAll`, progressive indexing. `createNote`/`updateNote` call `indexNote` directly with the one `Note` already in hand. `renameNote` reads/rewrites/saves wikilink-cascade candidates one file at a time (never holding more than one other note's body), then enqueues the renamed note plus any updated notes via `enqueueNotes(_:)` so ML embedding runs in the background instead of blocking the rename. `reloadExternalChanges` diffs by `modifiedAt`/`filename`/`tags`/`isBookmarked` (metadata only, no body read) to detect external changes. Browser-style navigation: `canNavigateBack`/`canNavigateForward`. External changes via `scheduleExternalReload`/`reloadExternalChanges`. |
| `SidebarMode` | `enum` in `mcpnotes-app`: `.all`, `.byTag`, `.favorites` (`symbolName`, `label`, `navigationTitle` per case), switched via a toolbar `Menu` in `SidebarView`. Search is **not** a mode — it's native `.searchable(text:)` state (`searchText`) layered on top, independent of `mode`; whenever `searchText` is non-empty, `SidebarView` shows results split into **Title** (filename match), **Content** (body/tag match, via `NoteStore.searchNoteBodies` — debounced, reads each candidate's body from disk one at a time), **Related** (RAG semantic matches with score %) instead of the selected mode's content. |
| `EditorViewModel` | `@Observable` class in `mcpnotes-app`. One instance per `NoteEditorView`. Owns autosave `Task`. |
| `FileService` | `struct` in `mcpnotes-app` conforming to `FileServicing`. Uses iCloud Drive, security-scoped bookmarks for custom directories, falls back to Application Support. `loadAllNotes()` (full body, all notes — used only by `AppIntents/*`'s own `FileService` instance) is kept alongside the metadata-only `loadAllNotesMetadata()` that `NoteStore` uses, plus `loadNote(at:)` for loading one note's body on demand and `setBookmarked(_:at:)` for flipping the bookmark flag without needing a full `Note` in hand. |
| `NoteMetadata` | `struct` in `mcpnotes-app` (`Models/NoteMetadata.swift`). Everything about a note except `body`: `id`, `filename`, `tags`, `fileURL`, `isBookmarked`, `modifiedAt`, `createdAt`, plus a bounded `preview` (stripped-markdown snippet of the first ~400 body chars, computed once when read) used for the sidebar row preview. `init(_ note: Note)` derives it from an already-loaded full `Note`. |
| `NoteFilenameValidator` | `struct` in `mcpnotes-app`. Allowlist: Unicode letters, digits, space, hyphen, underscore, period. `maxLength = 200`. Returns `ValidationResult`: `.valid`, `.empty`, `.tooLong`, `.forbiddenCharacter`. |
| `NoteIndexer` | **macOS-only.** `actor` in `mcpnotes-app`. Hybrid search: USearch vectors (multilingual-e5-small, 384-dim cosine) + SQLite FTS5 BM25. MD5-based incremental sync. `pending_removes`: `removeNote()` writes here synchronously; `loadFromDisk()` applies them on cold start + runs six integrity checks (returns `true` → full re-index needed); `saveToDisk()` clears them — idempotent across crashes. Embedding is delegated to an injected `any NoteEmbedding` (default: `XPCNoteEmbedder`). Files: `mcpnotes-app/NoteIndexer/`. `stripMarkdown` lives on `MarkdownPatterns` (shared), not here — it's also used by the iOS-visible `NoteListItemView` snippet/preview logic. |
| `NoOpNoteIndexer` | `actor` in `mcpnotes-app` (shared, unfiltered file). No-op `NoteIndexing` conformance used on iOS instead of `NoteIndexer`. |
| `NoteEmbedding` | **macOS-only.** `protocol` in `mcpnotes-app`. Single method `embed(_:) async throws -> [Float]`. Conformances: `XPCNoteEmbedder` (production), `MockNoteEmbedder` (tests). |
| `XPCNoteEmbedder` | **macOS-only.** `actor` in `mcpnotes-app`. Manages `NSXPCConnection` to `mcpnotes-embeddings` service. Cancels idle timer on each call; schedules 60 s close via `scheduleConnectionClose()`. |
| `IndexDatabase` | **macOS-only.** Private SQLite wrapper. Tables: chunk→key mappings, MD5 hashes, FTS5 full-text, tag index, note metadata, `pending_removes`. Used only by `NoteIndexer`. |
| `GraphSKView` | **macOS-only.** `SKView` subclass. Observes `NSWindow.didChangeOcclusionStateNotification` to restart SpriteKit's display link on reopen (SpriteKit stops it without going through `isPaused`). |
| `GraphSKScene` | **macOS-only.** `SKScene` subclass. Force-directed: O(n²) repulsion, spring edges, center gravity, `simAlpha` damping. |
| `NoteListItemView` | Sidebar row (shared, macOS + iOS). `searchQuery: String?` — replaces body preview with ±40-char snippet, match bolded, via `MarkdownPatterns.stripMarkdown`. `score: Float?` — semantic similarity % (RAG results, macOS only — never populated on iOS). `isSelected: Bool` — `SidebarView` paints this itself on iOS only (native inset-List selection tint is a dull gray there); macOS relies on the native accent-colored row selection instead. |
| `FilenameEditorView` | Platform-split (`+macOS.swift`/`+iOS.swift`), used by `FrontmatterView`. See [iOS support](#ios-support). |
| `MarkdownHighlighter` | Cross-platform `struct` (AppKit/UIKit typealiases + a `UIColor` extension shimming AppKit's semantic color names and `.traitItalic`/`.italic` symbolic-trait naming). Applies TextKit 2 attributes for CommonMark + GFM; used by both `MarkdownTextViewRepresentable+macOS.swift` and `+iOS.swift`. |
| `MarkdownTextView` | Two platform-specific subclasses sharing the name (mutually exclusive via platform-filtered files), both hosting `FrontmatterView` as a scrolling header (see Data flow above): `NSTextView` in `MarkdownTextViewRepresentable+macOS.swift` (pointing-hand cursor; single-click `[[wikilink]]`/`[text](url)` navigation; list auto-continuation on Enter; numbered list renumbering; image paste → saves file, inserts `![](filename)`; code-block copy button) and `UITextView` in `+iOS.swift` (tap navigation via `UITapGestureRecognizer`; list auto-continuation/renumbering; image paste; code-block copy button). |
| `TextFormatProxy` | Routes toolbar formatting to the active text view without coupling `NoteEditorView` to `MarkdownTextViewRepresentable`. Plain closure-holder, no AppKit/UIKit types itself — both platform representables register their own handlers. Cursor-aware, handles multi-line selections. |
| `ImportSettingsView` | **macOS-only.** Two flows: (1) Markdown folder via `NSOpenPanel`; (2) Apple Notes via `NSAppleScript` (HTML→Markdown via regex). Both write to `FileService.notesDirectoryURL`. |

### Directory watching

`NoteStore` watches the notes directory via `DispatchSource.makeFileSystemObjectSource` (events: `.write`, `.link`). Any external change (MCP server write, iCloud sync) triggers a 1 s debounced `reloadExternalChanges()` that diffs the current in-memory notes against fresh disk state, then: removes deleted notes from the index directly (`removeNote`), and enqueues only added/changed notes via `enqueueNotes(_:)`. The per-note queue worker calls `indexNoteIfChanged` — unchanged notes are skipped without ML inference.

### Apple Events from sandbox (macOS 26)

On macOS 26, `automation.apple-events` alone fails without a provisioning profile (error -600). `temporary-exception.apple-events` with `["com.apple.Notes", "com.apple.finder"]` works without a profile and correctly triggers the TCC dialog — both keys are required in `mcpnotes-app-macOS.entitlements`.

`NSAppleScript` must run on the main thread. Target Notes by bundle ID (`tell application id "com.apple.Notes"`), not by name.

## Swift conventions

- No force-unwrap (`!`) outside of tests.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` on the app target — all types implicitly `@MainActor`. Most file I/O in `NoteStore` uses `Task { }` (suspends on main actor, fine for quick local disk access). Exception: the initial `fileService.loadAllNotes()` in `NoteStore.load()` runs inside `Task.detached` — see [iOS support](#ios-support) for why (iCloud container resolution can block long enough to trip iOS's launch watchdog).
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest — except UI tests.
- Use `@Suite` to group tests. One suite per component.
- `NoteIndexerIntegrationTests.swift` uses real ML via XPC; model (~115 MB) is cached after first download. Requires `.timeLimit(.minutes(5))`.
- All other `NoteIndexer*Tests` suites inject `MockNoteEmbedder` — deterministic hash-based unit vectors, no ML, runs in milliseconds. Pass `NoteIndexer(storageDirectory: tmp, embedder: MockNoteEmbedder())`. Exception: `indexNoteIfChangedReindexesChangedBody` in `NoteIndexerIncrementalSyncTests` uses the XPC default (tests semantic ranking between two notes).
- `NoteStoreTests.swift` uses `MockFileService` and `MockNoteIndexer` (same file, no disk I/O). `MockNoteIndexer` tracks calls via `indexNoteCalledWith`, `indexNoteIfChangedCalledWith`, `removeNoteCalledWith`, `indexAllCalledWith`.
