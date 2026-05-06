import SwiftUI

struct SidebarView: View {
    @Environment(NoteStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ragEnabled") private var ragEnabled = false

    @State private var mode: SidebarMode = .all
    @State private var searchText: String = ""
    @State private var semanticNoteIDs: [UUID] = []
    @State private var searchTask: Task<Void, Never>?

    private var isRAGReady: Bool {
        if case .ready = store.indexingState { return true }
        return false
    }

    private var visibleNotes: [Note] {
        switch mode {
        case .all:
            return store.notes
        case .byTag:
            return store.notes
        case .favorites:
            return store.bookmarkedNotes
        case .search:
            guard !searchText.isEmpty else { return store.notes }
            if ragEnabled && isRAGReady && !semanticNoteIDs.isEmpty {
                return semanticNoteIDs.compactMap { id in store.notes.first { $0.id == id } }
            }
            let q = searchText.lowercased()
            return store.notes.filter {
                $0.filename.lowercased().contains(q) ||
                $0.body.lowercased().contains(q) ||
                $0.tags.contains { $0.lowercased().contains(q) }
            }
        }
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(SidebarMode.allCases, id: \.self) { m in
                    Image(systemName: m.symbolName)
                        .accessibilityLabel(m.label)
                        .tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Sidebar Mode")
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if mode == .search {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                Divider()
            }

            List(selection: $store.selectedNoteID) {
                if mode == .byTag {
                    tagGroupedContent
                } else {
                    flatContent
                }
            }
        }
        .navigationTitle("MCP Notes")
        .onChange(of: searchText) { triggerSemanticSearch() }
        .onChange(of: mode) {
            if mode != .search {
                searchText = ""
                semanticNoteIDs = []
                searchTask?.cancel()
            }
        }
        .toolbar { sidebarToolbar }
    }

    // MARK: - Semantic search

    private func triggerSemanticSearch() {
        searchTask?.cancel()
        guard ragEnabled && isRAGReady && !searchText.isEmpty else {
            semanticNoteIDs = []
            return
        }
        let query = searchText
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            semanticNoteIDs = (try? await store.search(query: query, expandLinks: false)) ?? []
        }
    }

    // MARK: - List content

    @ViewBuilder
    private var flatContent: some View {
        ForEach(visibleNotes) { note in
            NoteListItemView(note: note)
                .tag(note.id)
                .contextMenu { contextMenu(for: note) }
        }
        .onDelete { offsets in
            offsets.forEach { store.deleteNote(visibleNotes[$0]) }
        }
    }

    @ViewBuilder
    private var tagGroupedContent: some View {
        let untagged = store.notes.filter { $0.tags.isEmpty }

        ForEach(store.allTags, id: \.self) { tag in
            Section(tag) {
                ForEach(store.notes.filter { $0.tags.contains(tag) }) { note in
                    NoteListItemView(note: note)
                        .tag(note.id)
                        .contextMenu { contextMenu(for: note) }
                }
            }
        }

        if !untagged.isEmpty {
            Section("No Tags") {
                ForEach(untagged) { note in
                    NoteListItemView(note: note)
                        .tag(note.id)
                        .contextMenu { contextMenu(for: note) }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for note: Note) -> some View {
        Button("Open in New Window") {
            openWindow(value: note.id)
        }
        Divider()
        Button("Delete", role: .destructive) {
            store.deleteNote(note)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem {
            Button("New Note", systemImage: "square.and.pencil") {
                Task { await store.createNote() }
            }
            .accessibilityLabel("Create new note")
        }

        ToolbarItem {
            SettingsLink {
                Label("Settings", systemImage: "gear")
            }
            .accessibilityLabel("Open settings")
        }
    }
}
