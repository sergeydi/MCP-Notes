import SwiftUI

/// Displays and edits the note's filename, including rename validation and wikilink-cascade feedback.
/// macOS: the field is always directly editable — placing the cursor in it starts an edit.
/// Enter applies the rename (if valid); Escape or losing focus without Enter reverts the draft.
struct FilenameEditorView: View {
    let filename: String
    @Binding var draftFilename: String
    @Binding var isEditingFilename: Bool
    let isRenamingInProgress: Bool
    let wikilinkRenameCount: Int?
    let otherFilenames: [String]
    var onApplyRename: () -> Void

    private var trimmed: String { draftFilename.trimmingCharacters(in: .whitespaces) }
    private var validation: NoteFilenameValidator.ValidationResult { NoteFilenameValidator.validate(draftFilename) }
    private var hasConflict: Bool {
        validation == .valid && otherFilenames.contains { $0.lowercased() == trimmed.lowercased() }
    }
    private var canApply: Bool { validation == .valid && !hasConflict && trimmed != filename }
    private var isIdle: Bool { !isRenamingInProgress && wikilinkRenameCount == nil }
    @FocusState private var isFilenameFocused: Bool

    private func revertDraft() {
        guard isIdle else { return }
        draftFilename = filename
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $draftFilename)
                .textFieldStyle(.plain)
                .font(.title3.bold())
                .disabled(!isIdle)
                .focused($isFilenameFocused)
                .onSubmit { if canApply { onApplyRename() } else { revertDraft() } }
                .onKeyPress(.escape) {
                    revertDraft()
                    isFilenameFocused = false
                    return .handled
                }
                .onChange(of: isFilenameFocused) { _, focused in
                    isEditingFilename = focused
                    guard !focused else { return }
                    revertDraft()
                }
                .overlay(alignment: .bottom) {
                    if hasConflict {
                        Rectangle()
                            .fill(Color.red)
                            .frame(height: 1.5)
                    }
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
            } else if hasConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(String(localized: "A note with this filename already exists"))
            }
        }
    }
}
