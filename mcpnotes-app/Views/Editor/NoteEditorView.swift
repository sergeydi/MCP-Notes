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
        VStack(spacing: 0) {
            FrontmatterView(
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
            .zIndex(1)

            Divider()

            MarkdownEditorView(
                text: $viewModel.body,
                onTextChanged: viewModel.scheduleAutosave,
                onWikilinkTapped: { name in
                    if let target = store.notes.first(where: { $0.filename == name }) {
                        store.selectedNoteID = target.id
                    }
                },
                notesDirectoryURL: FileService.notesDirectoryURL,
                formatProxy: formatProxy
            )
        }
        .navigationTitle(note.filename)
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
        .onChange(of: note.id) { _, _ in
            viewModel.flushAutosave()
            viewModel.load(note: note)
            draftFilename = note.filename
            isEditingFilename = false
            renameMessageTask?.cancel()
            wikilinkRenameCount = nil
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
        .onDisappear {
            viewModel.flushAutosave()
        }
        .confirmationDialog("Delete \"\(note.filename)\"?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                viewModel.cancelAutosave()
                store.deleteNote(note)
            }
        } message: {
            Text("This note will be permanently deleted.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
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

        ToolbarItem {
            ControlGroup {
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

        ToolbarItem(placement: .primaryAction) {
            Button("Delete Note", systemImage: "trash", role: .destructive) {
                showDeleteConfirmation = true
            }
            .help("Delete note")
        }

        ToolbarItem(placement: .primaryAction) {
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
        }

        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: viewModel.body) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share note")
        }
    }
}
