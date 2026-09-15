import SwiftUI

struct SidebarView: View {
    @Environment(NoteStore.self) private var store
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif
    @AppStorage("ragEnabled") private var ragEnabled = false

    @State private var mode: SidebarMode = .all
    @State private var searchText: String = ""
    @State private var semanticResults: [(id: UUID, score: Float)] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var bodyMatches: [BodySearchMatch] = []
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var expandedTags: Set<String> = []
    @State private var noTagsExpanded: Bool = false

    private var isRAGReady: Bool {
        if case .ready = store.indexingState { return true }
        return false
    }

    private var semanticScores: [UUID: Float] {
        Dictionary(uniqueKeysWithValues: semanticResults.map { ($0.id, $0.score) })
    }

    private var visibleNotes: [NoteMetadata] {
        switch mode {
        case .all:
            return store.notes
        case .byTag:
            return store.notes
        case .favorites:
            return store.bookmarkedNotes
        }
    }

    var body: some View {
        @Bindable var store = store

            ScrollViewReader { proxy in
                List(selection: $store.selectedNoteID) {
                    if !searchText.isEmpty {
                        textSearchContent
                    } else if mode == .byTag {
                        tagGroupedContent
                    } else {
                        flatContent
                    }
                }
#if os(macOS)
                .environment(\.controlActiveState, .active)
#endif
                .onChange(of: searchText) {
                    proxy.scrollTo("search-top", anchor: .top)
                }
                .onChange(of: searchText) { _, newValue in
                    triggerContentSearch(newValue)
                }
                .onChange(of: store.bookmarkedNotes.map(\.id)) { oldIDs, newIDs in
                    // Bookmarked notes stay in the same alphabetical order as the main list,
                    // so a newly-bookmarked note can land anywhere in it — scroll to reveal it
                    // rather than leaving the list wherever it happened to be scrolled.
                    guard mode == .favorites, newIDs.count > oldIDs.count, let first = newIDs.first else { return }
                    withAnimation {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        .navigationTitle(mode.navigationTitle)
#if os(iOS)
        .searchable(text: $searchText, prompt: "Search")
#else
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
#endif
        .toolbar { sidebarToolbar }
    }

    // MARK: - Semantic search

    private func triggerSemanticSearch() {
        searchTask?.cancel()
        guard ragEnabled && isRAGReady && !searchText.isEmpty else {
            semanticResults = []
            return
        }
        let query = searchText
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            semanticResults = (try? await store.searchRanked(query: query)) ?? []
        }
    }

    /// Debounced "Content" search: reads candidate notes' bodies from disk asynchronously
    /// (see `NoteStore.searchNoteBodies`) instead of scanning `store.notes` in memory, since
    /// notes no longer carry a body once loaded. Mirrors `triggerSemanticSearch`'s 300ms
    /// debounce so a fast typist doesn't trigger a disk read per keystroke.
    private func triggerContentSearch(_ query: String) {
        contentSearchTask?.cancel()
        guard !query.isEmpty else { bodyMatches = []; return }
        let titleIDs = Set(textSearchTitleMatches.map(\.id))
        let candidates = store.notes.filter { !titleIDs.contains($0.id) }
        contentSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await store.searchNoteBodies(query: query, in: candidates)
            guard !Task.isCancelled else { return }
            bodyMatches = result
        }
    }

    // MARK: - List content

    /// The separator line between two rows is shared: hiding it only on the selected
    /// row's own edge leaves the neighbor's edge still drawing it. Hide it from both sides.
    private func rowSeparatorEdges(for id: UUID, in ids: [UUID]) -> (top: Visibility, bottom: Visibility) {
        guard let idx = ids.firstIndex(of: id) else { return (.visible, .visible) }
        let selected = store.selectedNoteID
        let isSelected = id == selected
        let prevSelected = idx > 0 && ids[idx - 1] == selected
        let nextSelected = idx < ids.count - 1 && ids[idx + 1] == selected
        return (
            top: (isSelected || prevSelected) ? .hidden : .visible,
            bottom: (isSelected || nextSelected) ? .hidden : .visible
        )
    }

    /// macOS renders the accent-colored selection natively (see `.controlActiveState` above);
    /// iOS's plain/inset List selection is a dull gray, so paint it ourselves there.
    private func isRowSelected(_ id: UUID) -> Bool {
#if os(iOS)
        id == store.selectedNoteID
#else
        false
#endif
    }

    @ViewBuilder
    private func rowBackground(for id: UUID) -> some View {
        if isRowSelected(id) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor)
        } else {
            Color.clear
        }
    }

    private var textSearchTitleMatches: [NoteMetadata] {
        let q = searchText.lowercased()
        return store.notes.filter { $0.filename.lowercased().contains(q) }
    }

    @ViewBuilder
    private var flatContent: some View {
        let ids = visibleNotes.map(\.id)
        ForEach(visibleNotes) { note in
            let edges = rowSeparatorEdges(for: note.id, in: ids)
            NoteListItemView(note: note, isSelected: isRowSelected(note.id))
                .tag(note.id)
                .listRowSeparator(edges.top, edges: .top)
                .listRowSeparator(edges.bottom, edges: .bottom)
                .listRowBackground(rowBackground(for: note.id))
        }
        .onDelete { offsets in
            offsets.forEach { store.deleteNote(visibleNotes[$0]) }
        }
    }

    @ViewBuilder
    private var textSearchContent: some View {
        let titleMatches = textSearchTitleMatches
        let shownIDs = Set(titleMatches.map { $0.id } + bodyMatches.map { $0.id })
        let semanticMatches = semanticResults
            .filter { !shownIDs.contains($0.id) }
            .compactMap { r in store.notes.first { $0.id == r.id }.map { ($0, r.score) } }

        let titleIDs = titleMatches.map(\.id)
        let bodyIDs = bodyMatches.map(\.id)
        let semanticIDs = semanticMatches.map(\.0.id)

        if !titleMatches.isEmpty {
            Section {
                ForEach(titleMatches) { note in
                    let edges = rowSeparatorEdges(for: note.id, in: titleIDs)
                    NoteListItemView(note: note, searchQuery: searchText, isSelected: isRowSelected(note.id))
                        .tag(note.id)
                        .listRowSeparator(edges.top, edges: .top)
                        .listRowSeparator(edges.bottom, edges: .bottom)
                        .listRowBackground(rowBackground(for: note.id))
                }
            } header: {
                Text("Title").id("search-top")
            }
            if !bodyMatches.isEmpty {
                Section("Content") {
                    ForEach(bodyMatches) { match in
                        let edges = rowSeparatorEdges(for: match.id, in: bodyIDs)
                        NoteListItemView(note: match.metadata, searchQuery: searchText, searchSnippet: match.match, isSelected: isRowSelected(match.id))
                            .tag(match.id)
                            .listRowSeparator(edges.top, edges: .top)
                            .listRowSeparator(edges.bottom, edges: .bottom)
                            .listRowBackground(rowBackground(for: match.id))
                    }
                }
            }
        } else if !bodyMatches.isEmpty {
            Section {
                ForEach(bodyMatches) { match in
                    let edges = rowSeparatorEdges(for: match.id, in: bodyIDs)
                    NoteListItemView(note: match.metadata, searchQuery: searchText, searchSnippet: match.match, isSelected: isRowSelected(match.id))
                        .tag(match.id)
                        .listRowSeparator(edges.top, edges: .top)
                        .listRowSeparator(edges.bottom, edges: .bottom)
                        .listRowBackground(rowBackground(for: match.id))
                }
            } header: {
                Text("Content").id("search-top")
            }
        }

        if !semanticMatches.isEmpty {
            Section("Related") {
                ForEach(semanticMatches, id: \.0.id) { note, score in
                    let edges = rowSeparatorEdges(for: note.id, in: semanticIDs)
                    NoteListItemView(note: note, score: score, isSelected: isRowSelected(note.id))
                        .tag(note.id)
                        .listRowSeparator(edges.top, edges: .top)
                        .listRowSeparator(edges.bottom, edges: .bottom)
                        .listRowBackground(rowBackground(for: note.id))
                }
            }
        }
    }

    private func tagDisclosureBinding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { expandedTags.contains(tag) },
            set: { isExpanded in
                if isExpanded { expandedTags.insert(tag) }
                else { expandedTags.remove(tag) }
            }
        )
    }

    @ViewBuilder
    private func tagDisclosureLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var tagGroupedContent: some View {
        let untagged = store.notes.filter { $0.tags.isEmpty }

        ForEach(store.allTags, id: \.self) { tag in
            let tagNotes = store.notes.filter { $0.tags.contains(tag) }
            let ids = tagNotes.map(\.id)
            DisclosureGroup(isExpanded: tagDisclosureBinding(for: tag)) {
                ForEach(tagNotes) { note in
                    let edges = rowSeparatorEdges(for: note.id, in: ids)
                    NoteListItemView(note: note, isSelected: isRowSelected(note.id))
                        .tag(note.id)
                        .listRowSeparator(edges.top, edges: .top)
                        .listRowSeparator(edges.bottom, edges: .bottom)
                        .listRowBackground(rowBackground(for: note.id))
                }
            } label: {
                tagDisclosureLabel(tag, count: tagNotes.count)
            }
        }

        if !untagged.isEmpty {
            let ids = untagged.map(\.id)
            DisclosureGroup(isExpanded: $noTagsExpanded) {
                ForEach(untagged) { note in
                    let edges = rowSeparatorEdges(for: note.id, in: ids)
                    NoteListItemView(note: note, isSelected: isRowSelected(note.id))
                        .tag(note.id)
                        .listRowSeparator(edges.top, edges: .top)
                        .listRowSeparator(edges.bottom, edges: .bottom)
                        .listRowBackground(rowBackground(for: note.id))
                }
            } label: {
                tagDisclosureLabel("No Tags", count: untagged.count)
            }
        }
    }

    // MARK: - Toolbar
#if os(iOS)
    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        if store.isLoading {
            ToolbarItem(placement: .topBarLeading) {
                ProgressView()
                    .accessibilityLabel("Loading notes")
            }
        }

        ToolbarItem {
            ControlGroup {
                ForEach(SidebarMode.allCases, id: \.self) { m in
                    Button {
                        mode = m
                    } label: {
                        Label(m.label, systemImage: m.symbolName)
                    }
                    .tint(mode == m ? Color.accentColor : nil)
                }
            }
        }

        DefaultToolbarItem(kind: .search, placement: .bottomBar)

        ToolbarSpacer(placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            Button("New Note", systemImage: "square.and.pencil") {
                Task { await store.createNote() }
            }
            .accessibilityLabel("Create new note")
        }
    }
#else
    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        if store.isLoading {
            ToolbarItem(placement: .navigation) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading notes")
            }
        }

        ToolbarItem {
            Menu {
                ForEach(SidebarMode.allCases, id: \.self) { m in
                    Button {
                        mode = m
                    } label: {
                        Label(m.label, systemImage: m.symbolName)
                    }
                }
            } label: {
                Image(systemName: mode.symbolName)
            }
            .help(mode.label)
            .accessibilityLabel(mode.label)
        }

        ToolbarItem {
            Button("New Note", systemImage: "square.and.pencil") {
                Task { await store.createNote() }
            }
            .accessibilityLabel("Create new note")
        }

        ToolbarItem {
            SettingsLink {
                Image(systemName: "gear")
                    .overlay(alignment: .bottomTrailing) {
                        if store.indexingState.isIndexing {
                            IndexingDot()
                                .offset(x: 4, y: 4)
                        }
                    }
            }
            .accessibilityLabel("Open settings")
        }

        ToolbarItem {
            Button {
                openWindow(id: "wikilink-graph")
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .help("Show Wikilink Graph")
        }
    }
#endif
}
