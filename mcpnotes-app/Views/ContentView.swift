import SwiftUI

struct ContentView: View {
    @Environment(NoteStore.self) private var store
    @State private var showRecoveryAlert = false

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
        .onChange(of: store.indexWasRecovered) { _, recovered in
            if recovered { showRecoveryAlert = true }
        }
        .alert("Search Index Rebuilt", isPresented: $showRecoveryAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The search index was corrupted and has been reset. Your notes are being re-indexed now.")
        }
    }
}

#Preview {
#if os(macOS)
    ContentView()
        .environment(NoteStore(indexer: NoteIndexer()))
#else
    ContentView()
        .environment(NoteStore(indexer: NoOpNoteIndexer()))
#endif
}
