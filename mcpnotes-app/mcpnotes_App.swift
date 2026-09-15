import SwiftUI

@main
struct MCPNotesApp: App {
#if os(macOS)
    @State private var noteStore = NoteStore(indexer: NoteIndexer())
#else
    @State private var noteStore = NoteStore(indexer: NoOpNoteIndexer())
#endif
    @Environment(\.scenePhase) private var scenePhase

    // Skip SwiftUI UI initialization during test runs to avoid crashes in macOS 26 beta
    // system frameworks (NSSplitView, DynamicPropertyBuffer) before the test runner connects.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                EmptyView()
            } else {
                ContentView()
                    .environment(noteStore)
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Note") {
                    Task { await noteStore.createNote() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        // App Intents (Siri/Shortcuts) can run in a separate, background instance of this app's
        // process even while this one is already open — its writes land on disk via FileService,
        // but this instance's live directory watcher can't reliably deliver that change while
        // suspended (no run loop to dispatch the kqueue event). Re-running the same external-change
        // pipeline used for MCP server writes and iCloud sync on every foreground guarantees this
        // instance picks up whatever changed while it was away, regardless of who wrote it.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            noteStore.scheduleExternalReload()
            if let pendingNoteID = PendingNoteNavigation.consume() {
                noteStore.selectedNoteID = pendingNoteID
            }
        }

        // Opens a specific note in a standalone window via context menu.
        WindowGroup(for: UUID.self) { $noteID in
            if let id = noteID, let note = noteStore.notes.first(where: { $0.id == id }) {
                NoteEditorView(noteMetadata: note)
                    .environment(noteStore)
                    .frame(minWidth: 500, minHeight: 400)
            }
        }

#if os(macOS)
        Window("Wikilink Graph", id: "wikilink-graph") {
            WikilinkGraphView()
                .environment(noteStore)
                .frame(minWidth: 400, minHeight: 300)
        }
        .defaultSize(width: 800, height: 600)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(noteStore)
        }
#endif
    }
}
