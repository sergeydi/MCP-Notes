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
    @State private var expandedTags: Set<String> = []
    @State private var noTagsExpanded: Bool = false

    private var isRAGReady: Bool {
        if case .ready = store.indexingState { return true }
        return false
    }

    private var semanticScores: [UUID: Float] {
        Dictionary(uniqueKeysWithValues: semanticResults.map { ($0.id, $0.score) })
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
            guard !searchText.isEmpty else { return [] }
            if ragEnabled && isRAGReady && !semanticResults.isEmpty {
                return semanticResults.compactMap { r in store.notes.first { $0.id == r.id } }
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
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(SidebarMode.allCases, id: \.self) { m in
                    Button {
                        mode = m
                    } label: {
                        Image(systemName: m.symbolName)
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(mode == m ? Color.accentColor : Color.clear)
                            )
                            .foregroundStyle(mode == m ? Color.white : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(m.label)
                    .accessibilityLabel(m.label)
                    Spacer(minLength: 0)
                }
#if os(macOS)
                Divider()
                    .frame(height: 18)
                Spacer(minLength: 0)
                Button {
                    openWindow(id: "wikilink-graph")
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Wikilink Graph")
                Spacer(minLength: 0)
#endif
            }
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

            ScrollViewReader { proxy in
                List(selection: $store.selectedNoteID) {
                    if store.isLoading {
                        loadingContent
                    } else if mode == .byTag {
                        tagGroupedContent
                    } else {
                        flatContent
                    }
                }
                .padding(.top, 8)
#if os(macOS)
                .environment(\.controlActiveState, .active)
#endif
                .onChange(of: searchText) {
                    proxy.scrollTo("search-top", anchor: .top)
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
        }
        .navigationSplitViewColumnWidth(min: 350, ideal: 350)
        .navigationTitle("MCP Notes")
        .onChange(of: searchText) { triggerSemanticSearch() }
        .onChange(of: mode) {
            if mode != .search {
                searchText = ""
                semanticResults = []
                searchTask?.cancel()
            }
        }
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

    @ViewBuilder
    private var loadingContent: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    private var textSearchTitleMatches: [Note] {
        let q = searchText.lowercased()
        return store.notes.filter { $0.filename.lowercased().contains(q) }
    }

    private var textSearchBodyMatches: [Note] {
        let q = searchText.lowercased()
        let titleIDs = Set(textSearchTitleMatches.map { $0.id })
        return store.notes.filter {
            !titleIDs.contains($0.id) &&
            ($0.body.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) })
        }
    }

    @ViewBuilder
    private var flatContent: some View {
        if mode == .search && !searchText.isEmpty {
            textSearchContent
        } else {
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
    }

    @ViewBuilder
    private var textSearchContent: some View {
        let titleMatches = textSearchTitleMatches
        let bodyMatches = textSearchBodyMatches
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
                    ForEach(bodyMatches) { note in
                        let edges = rowSeparatorEdges(for: note.id, in: bodyIDs)
                        NoteListItemView(note: note, searchQuery: searchText, isSelected: isRowSelected(note.id))
                            .tag(note.id)
                            .listRowSeparator(edges.top, edges: .top)
                            .listRowSeparator(edges.bottom, edges: .bottom)
                            .listRowBackground(rowBackground(for: note.id))
                    }
                }
            }
        } else if !bodyMatches.isEmpty {
            Section {
                ForEach(bodyMatches) { note in
                    let edges = rowSeparatorEdges(for: note.id, in: bodyIDs)
                    NoteListItemView(note: note, searchQuery: searchText, isSelected: isRowSelected(note.id))
                        .tag(note.id)
                        .listRowSeparator(edges.top, edges: .top)
                        .listRowSeparator(edges.bottom, edges: .bottom)
                        .listRowBackground(rowBackground(for: note.id))
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

    @ViewBuilder
    private var tagGroupedContent: some View {
        let untagged = store.notes.filter { $0.tags.isEmpty }

        ForEach(store.allTags, id: \.self) { tag in
            let tagNotes = store.notes.filter { $0.tags.contains(tag) }
            let isExpanded = expandedTags.contains(tag)
            Section {
                if isExpanded {
                    let ids = tagNotes.map(\.id)
                    ForEach(tagNotes) { note in
                        let edges = rowSeparatorEdges(for: note.id, in: ids)
                        NoteListItemView(note: note, isSelected: isRowSelected(note.id))
                            .tag(note.id)
                            .listRowSeparator(edges.top, edges: .top)
                            .listRowSeparator(edges.bottom, edges: .bottom)
                            .listRowBackground(rowBackground(for: note.id))
                    }
                }
            } header: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded { expandedTags.remove(tag) }
                        else { expandedTags.insert(tag) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(tag)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(tagNotes.count)")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        if !untagged.isEmpty {
            Section {
                if noTagsExpanded {
                    let ids = untagged.map(\.id)
                    ForEach(untagged) { note in
                        let edges = rowSeparatorEdges(for: note.id, in: ids)
                        NoteListItemView(note: note, isSelected: isRowSelected(note.id))
                            .tag(note.id)
                            .listRowSeparator(edges.top, edges: .top)
                            .listRowSeparator(edges.bottom, edges: .bottom)
                            .listRowBackground(rowBackground(for: note.id))
                    }
                }
            } header: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        noTagsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(noTagsExpanded ? 90 : 0))
                        Text("No Tags")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(untagged.count)")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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

#if os(macOS)
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
#endif
    }
}

#if os(macOS)
private struct IndexingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 1.0 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
#endif
