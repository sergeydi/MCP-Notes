import SwiftUI

@main
struct MCPNotesApp: App {
    @State private var noteStore = NoteStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(noteStore)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Note") {
                    Task { await noteStore.createNote() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        // Opens a specific note in a standalone window via context menu.
        WindowGroup(for: UUID.self) { $noteID in
            if let id = noteID, let note = noteStore.notes.first(where: { $0.id == id }) {
                NoteEditorView(note: note)
                    .environment(noteStore)
                    .frame(minWidth: 500, minHeight: 400)
            }
        }

        Settings {
            SettingsView()
                .environment(noteStore)
        }
    }
}
