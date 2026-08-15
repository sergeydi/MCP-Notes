import SwiftUI

struct NoteEditorView: View {
    @Environment(NoteStore.self) private var store
    let note: Note

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
                filename: note.filename,
                draftFilename: $draftFilename,
                isEditingFilename: $isEditingFilename,
                isRenamingInProgress: isRenamingInProgress,
                wikilinkRenameCount: wikilinkRenameCount,
                otherFilenames: store.notes.filter { $0.id != note.id }.map(\.filename),
                tags: $viewModel.tags,
                allTags: store.allTags,
                onTagsChanged: viewModel.scheduleAutosave,
                onApplyRename: {
                    let oldName = note.filename
                    let newName = draftFilename.trimmingCharacters(in: .whitespaces)
                    viewModel.flushAutosave()
                    renameMessageTask?.cancel()
                    renameMessageTask = nil
                    isRenamingInProgress = true
                    wikilinkRenameCount = nil
                    store.renameNote(note, to: newName) { updatedFilenames in
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
        .onAppear {
            viewModel.load(note: note)
            draftFilename = note.filename
            let noteID = note.id
            viewModel.onSave = { [weak store] body, tags in
                guard let store else { return }
                guard let current = store.notes.first(where: { $0.id == noteID }) else { return }
                var updated = current
                updated.body = body
                updated.tags = tags
                store.updateNote(updated)
            }
        }
        .onChange(of: note) { oldValue, newValue in
            guard newValue.id != oldValue.id else {
                // Same note, changed externally (e.g. iCloud sync from another device).
                // Only pull in the fresh content if the user has no unsaved local edits —
                // otherwise we'd clobber what they're currently typing.
                guard !viewModel.isDirty else { return }
                viewModel.load(note: newValue)
                if !isEditingFilename {
                    draftFilename = newValue.filename
                }
                return
            }
            viewModel.flushAutosave()
            viewModel.load(note: newValue)
            draftFilename = newValue.filename
            isEditingFilename = false
            renameMessageTask?.cancel()
            wikilinkRenameCount = nil
            let noteID = newValue.id
            viewModel.onSave = { [weak store] body, tags in
                guard let store else { return }
                guard let current = store.notes.first(where: { $0.id == noteID }) else { return }
                var updated = current
                updated.body = body
                updated.tags = tags
                store.updateNote(updated)
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
                    WikilinkPickerView(notes: store.notes.filter { $0.id != note.id }) { wikilink in
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
            .confirmationDialog("Delete \"\(note.filename)\"?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    viewModel.cancelAutosave()
                    store.deleteNote(note)
                }
            } message: {
                Text("This note will be permanently deleted.")
            }

            Button {
                store.toggleBookmark(for: note.id)
            } label: {
                Label(
                    note.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: note.isBookmarked ? "bookmark.fill" : "bookmark"
                )
                .foregroundStyle(note.isBookmarked ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel(note.isBookmarked ? "Remove bookmark" : "Add bookmark")
            .help(note.isBookmarked ? "Remove bookmark" : "Add bookmark")

            ShareLink(item: viewModel.body) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share note")
        }
    }
}
