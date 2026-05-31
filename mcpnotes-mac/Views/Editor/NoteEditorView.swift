import MCPNotesCore
import SwiftUI

struct NoteEditorView: View {
    @Environment(NoteStore.self) private var store
    let note: Note

    @State private var viewModel = EditorViewModel()
    @State private var showDeleteConfirmation = false
    @State private var formatProxy = TextFormatProxy()
    @State private var showWikilinkPicker = false

    var body: some View {
        VStack(spacing: 0) {
            FrontmatterView(
                tags: $viewModel.tags,
                allTags: store.allTags,
                onTagsChanged: viewModel.scheduleAutosave
            )

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
            viewModel.onSave = { [weak store] body, tags in
                guard let store else { return }
                var updated = note
                updated.body = body
                updated.tags = tags
                store.updateNote(updated)
            }
        }
        .onChange(of: note.id) { _, _ in
            viewModel.flushAutosave()
            viewModel.load(note: note)
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
