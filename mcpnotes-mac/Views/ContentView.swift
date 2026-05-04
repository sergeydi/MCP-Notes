import SwiftUI

struct ContentView: View {
    @Environment(NoteStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let note = store.selectedNote {
                NoteEditorView(note: note)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Select a note from the sidebar or create a new one.")
                )
            }
        }
        .task {
            await store.load()
        }
    }
}

#Preview {
    ContentView()
        .environment(NoteStore())
}
