import SwiftUI

/// Displays the note's YAML frontmatter.
/// The filename row allows renaming; the tags row allows editing.
struct FrontmatterView: View {
    let filename: String
    @Binding var draftFilename: String
    @Binding var isEditingFilename: Bool
    let isRenamingInProgress: Bool
    let wikilinkRenameCount: Int?
    let otherFilenames: [String]
    @Binding var tags: [String]
    let allTags: [String]
    var onTagsChanged: () -> Void
    var onApplyRename: () -> Void

    private var trimmed: String { draftFilename.trimmingCharacters(in: .whitespaces) }
    private var validation: NoteFilenameValidator.ValidationResult { NoteFilenameValidator.validate(draftFilename) }
    private var hasConflict: Bool {
        validation == .valid && otherFilenames.contains { $0.lowercased() == trimmed.lowercased() }
    }
    private var canApply: Bool { validation == .valid && !hasConflict && trimmed != filename }
    private var isIdle: Bool { !isRenamingInProgress && wikilinkRenameCount == nil }
    @FocusState private var isFilenameFocused: Bool
    @State private var filenameSelection: TextSelection?

    private func cancelEdit() {
        guard isIdle else { return }
        draftFilename = filename
        isEditingFilename = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isEditingFilename {
                    TextField("", text: $draftFilename, selection: $filenameSelection)
                        .textFieldStyle(.plain)
                        .disabled(!isIdle)
                        .focused($isFilenameFocused)
                        .onSubmit { if canApply { onApplyRename() } else { cancelEdit() } }
                        .onKeyPress(.escape) {
                            cancelEdit()
                            return .handled
                        }
                        .onAppear {
                            guard isIdle else { return }
                            filenameSelection = TextSelection(insertionPoint: draftFilename.endIndex)
                            isFilenameFocused = true
                        }
                        .onChange(of: isFilenameFocused) { _, focused in
                            guard focused, isIdle else { return }
                            filenameSelection = TextSelection(insertionPoint: draftFilename.endIndex)
                        }

                    if isRenamingInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else if let count = wikilinkRenameCount {
                        Text(count == 0
                             ? String(localized: "No wikilinks updated")
                             : count == 1
                                ? String(localized: "1 wikilink updated")
                                : String(localized: "\(count) wikilinks updated"))
                            .foregroundStyle(.secondary)
                    } else {
                        if hasConflict {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(String(localized: "A note with this filename already exists"))
                        }

                        Button("Apply", action: onApplyRename)
                            .disabled(!canApply)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(canApply ? Color.primary : Color.secondary)
                    }
                } else {
                    Text(filename)
                        .textSelection(.enabled)

                    Button {
                        draftFilename = filename
                        isEditingFilename = true
                    } label: {
                        Image(systemName: "pencil").imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Edit filename")
                }
            }

            Divider()

            TagsEditorView(tags: $tags, allTags: allTags, onChange: onTagsChanged)
        }
        .font(.callout)
        .padding()
        .background(.background)
    }
}
