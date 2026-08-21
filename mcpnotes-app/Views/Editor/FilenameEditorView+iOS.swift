import SwiftUI

/// Displays and edits the note's filename, including rename validation and wikilink-cascade feedback.
/// iPad: touch-first layout — 44pt-minimum tap targets, an explicit Cancel button (no hardware Escape
/// key to rely on), and the whole name selected on focus so retyping doesn't require manual deletion.
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
    @State private var filenameSelection: TextSelection?

    private func cancelEdit() {
        guard isIdle else { return }
        draftFilename = filename
        isEditingFilename = false
    }

    private func selectAll() {
        filenameSelection = TextSelection(range: draftFilename.startIndex..<draftFilename.endIndex)
    }

    var body: some View {
        HStack(spacing: 10) {
            if isEditingFilename {
                TextField("", text: $draftFilename, selection: $filenameSelection)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .disabled(!isIdle)
                    .focused($isFilenameFocused)
                    .onSubmit { if canApply { onApplyRename() } else { cancelEdit() } }
                    .onAppear {
                        guard isIdle else { return }
                        selectAll()
                        isFilenameFocused = true
                    }
                    .onChange(of: isFilenameFocused) { _, focused in
                        guard focused, isIdle else { return }
                        selectAll()
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
                    }

                    Button(action: cancelEdit) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button(action: onApplyRename) {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.large)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canApply)
                    .foregroundStyle(canApply ? Color.accentColor : Color.secondary)
                }
            } else {
                Text(filename)
                    .font(.title3.bold())
                    .textSelection(.enabled)

                Button {
                    draftFilename = filename
                    isEditingFilename = true
                } label: {
                    Image(systemName: "pencil")
                        .imageScale(.large)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
