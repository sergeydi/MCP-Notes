import SwiftUI

struct NoteEditorView: View {
    @Environment(NoteStore.self) private var store
    let note: Note

    @State private var viewModel = EditorViewModel()
    @State private var showDeleteConfirmation = false

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
                }
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

        ToolbarItemGroup {
            headingsMenu
            styleMenu
            blocksMenu
            listsMenu
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
            }
            .accessibilityLabel(note.isBookmarked ? "Remove bookmark" : "Add bookmark")
        }

        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: viewModel.body) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var headingsMenu: some View {
        Menu {
            Button("Heading 1") { insertPrefix("# ") }
            Button("Heading 2") { insertPrefix("## ") }
            Button("Heading 3") { insertPrefix("### ") }
        } label: {
            Label("Headings", systemImage: "textformat.size")
        }
        .accessibilityLabel("Insert heading")
    }

    private var styleMenu: some View {
        Menu {
            Button("Bold")          { insertWrapped(with: "**") }
            Button("Italic")        { insertWrapped(with: "_") }
            Button("Strikethrough") { insertWrapped(with: "~~") }
        } label: {
            Label("Style", systemImage: "bold")
        }
        .accessibilityLabel("Insert text style")
    }

    private var blocksMenu: some View {
        Menu {
            Button("Quote")       { insertPrefix("> ") }
            Button("Inline Code") { insertWrapped(with: "`") }
            Button("Code Block")  { insertWrapped(with: "```\n", closing: "\n```") }
        } label: {
            Label("Blocks", systemImage: "quote.bubble")
        }
        .accessibilityLabel("Insert block")
    }

    private var listsMenu: some View {
        Menu {
            Button("Bullet List")   { insertPrefix("- ") }
            Button("Numbered List") { insertPrefix("1. ") }
            Button("Task")          { insertPrefix("- [ ] ") }
        } label: {
            Label("Lists", systemImage: "list.bullet")
        }
        .accessibilityLabel("Insert list")
    }

    // Inserts a line prefix — cursor-aware insertion requires NSTextView integration (future work).
    private func insertPrefix(_ prefix: String) {
        viewModel.body += "\n" + prefix
        viewModel.scheduleAutosave()
    }

    private func insertWrapped(with delimiter: String, closing: String? = nil) {
        let close = closing ?? delimiter
        viewModel.body += delimiter + close
        viewModel.scheduleAutosave()
    }
}
