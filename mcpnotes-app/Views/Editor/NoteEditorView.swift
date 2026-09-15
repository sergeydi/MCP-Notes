import SwiftUI

struct NoteEditorView: View {
    @Environment(NoteStore.self) private var store
    let noteMetadata: NoteMetadata

    @State private var viewModel = EditorViewModel()
    @State private var showDeleteConfirmation = false
    @State private var formatProxy = TextFormatProxy()
    @State private var showWikilinkPicker = false
    @State private var draftFilename: String = ""
    @State private var isEditingFilename = false
    @State private var isRenamingInProgress = false
    @State private var wikilinkRenameCount: Int? = nil
    @State private var renameMessageTask: Task<Void, Never>? = nil

    var body: some View {
        MarkdownEditorView(
            text: $viewModel.body,
            onTextChanged: viewModel.scheduleAutosave,
            onWikilinkTapped: { name in
                if let target = store.notes.first(where: { $0.filename == name }) {
                    store.selectedNoteID = target.id
                }
            },
            notesDirectoryURL: FileService.notesDirectoryURL,
            formatProxy: formatProxy,
            header: FrontmatterView(
                filename: noteMetadata.filename,
                draftFilename: $draftFilename,
                isEditingFilename: $isEditingFilename,
                isRenamingInProgress: isRenamingInProgress,
                wikilinkRenameCount: wikilinkRenameCount,
                otherFilenames: store.notes.filter { $0.id != noteMetadata.id }.map(\.filename),
                tags: $viewModel.tags,
                allTags: store.allTags,
                onTagsChanged: viewModel.scheduleAutosave,
                onApplyRename: {
                    let oldName = noteMetadata.filename
                    let newName = draftFilename.trimmingCharacters(in: .whitespaces)
                    viewModel.flushAutosave()
                    renameMessageTask?.cancel()
                    renameMessageTask = nil
                    isRenamingInProgress = true
                    wikilinkRenameCount = nil
                    store.renameNote(noteMetadata, to: newName) { updatedFilenames in
                        isRenamingInProgress = false
                        wikilinkRenameCount = updatedFilenames.count
                        renameMessageTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            wikilinkRenameCount = nil
                            isEditingFilename = false
                        }
                    }
                }
            )
        )
        .toolbar { editorToolbar }
        .task(id: noteMetadata.id) {
            let noteID = noteMetadata.id
            guard let full = try? await store.loadFullNote(noteMetadata) else { return }
            viewModel.load(note: full)
            draftFilename = full.filename
            // Looks up the note fresh from the store by id at save time (rather than closing
            // over `noteMetadata`/`full`) so a rename that lands between now and the next
            // autosave is reflected in the fileURL/filename we save to.
            viewModel.onSave = { [weak store] body, tags in
                guard let store, let current = store.notes.first(where: { $0.id == noteID }) else { return }
                let updated = Note(
                    id: current.id,
                    filename: current.filename,
                    tags: tags,
                    body: body,
                    fileURL: current.fileURL,
                    isBookmarked: current.isBookmarked,
                    modifiedAt: current.modifiedAt,
                    createdAt: current.createdAt
                )
                store.updateNote(updated)
            }
        }
        .onChange(of: noteMetadata) { oldValue, newValue in
            // View identity is `.id(note.id)` upstream, so a different note always gets a
            // fresh NoteEditorView instance — this only ever fires for the same note changed
            // externally (e.g. iCloud sync from another device, or the MCP server writing to
            // it). Only pull in fresh content if the user has no unsaved local edits —
            // otherwise we'd clobber what they're currently typing.
            guard !viewModel.isDirty else { return }
            guard newValue.modifiedAt != oldValue.modifiedAt || newValue.filename != oldValue.filename else { return }
            Task {
                guard let full = try? await store.loadFullNote(newValue) else { return }
                viewModel.load(note: full)
            }
            if !isEditingFilename {
                draftFilename = newValue.filename
            }
        }
        .onDisappear {
            viewModel.flushAutosave()
        }
    }

    // MARK: - Toolbar

    private var navigationPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: navigationPlacement) {
            Button { store.navigateBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canNavigateBack)
            .help("Back")

            Button { store.navigateForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!store.canNavigateForward)
            .help("Forward")
        }

        ToolbarItemGroup {
            ControlGroup("Format", systemImage: "textformat") {
                Button { formatProxy.applyWrap("**", "**") } label: {
                    Label("Bold", systemImage: "bold")
                }
                .help("Bold")
                Button { formatProxy.applyWrap("_", "_") } label: {
                    Label("Italic", systemImage: "italic")
                }
                .help("Italic")
                Button { formatProxy.applyWrap("~~", "~~") } label: {
                    Label("Strikethrough", systemImage: "strikethrough")
                }
                .help("Strikethrough")
                Button { formatProxy.applyCode() } label: {
                    Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Code")
                Button { formatProxy.applyPrefix("- ") } label: {
                    Label("Bullet List", systemImage: "list.bullet")
                }
                .help("Bullet list")
                Button { formatProxy.applyPrefix("1. ") } label: {
                    Label("Numbered List", systemImage: "list.number")
                }
                .help("Numbered list")
                Button { showWikilinkPicker = true } label: {
                    Label("Insert Link", systemImage: "link.badge.plus")
                }
                .help("Insert wikilink")
                .popover(isPresented: $showWikilinkPicker, arrowEdge: .bottom) {
                    WikilinkPickerView(notes: store.notes.filter { $0.id != noteMetadata.id }) { wikilink in
                        formatProxy.insertText(wikilink)
                        showWikilinkPicker = false
                    }
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Delete Note", systemImage: "trash", role: .destructive) {
                showDeleteConfirmation = true
            }
            .help("Delete note")
            .confirmationDialog("Delete \"\(noteMetadata.filename)\"?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    viewModel.cancelAutosave()
                    store.deleteNote(noteMetadata)
                }
            } message: {
                Text("This note will be permanently deleted.")
            }

            Button {
                store.toggleBookmark(for: noteMetadata.id)
            } label: {
                Label(
                    noteMetadata.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: noteMetadata.isBookmarked ? "bookmark.fill" : "bookmark"
                )
                .foregroundStyle(noteMetadata.isBookmarked ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel(noteMetadata.isBookmarked ? "Remove bookmark" : "Add bookmark")
            .help(noteMetadata.isBookmarked ? "Remove bookmark" : "Add bookmark")

            ShareLink(item: viewModel.body) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share note")
        }
    }
}
