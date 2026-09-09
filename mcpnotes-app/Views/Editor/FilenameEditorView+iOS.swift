import SwiftUI
import UIKit

/// Displays and edits the note's filename, including rename validation and wikilink-cascade feedback.
/// iPad: touch-first layout — 44pt-minimum tap targets, an explicit Cancel button (no hardware Escape
/// key to rely on), and the whole name selected on focus so retyping doesn't require manual deletion.
/// Editing starts as soon as the cursor is placed in the field — there is no separate edit button.
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
    private var isEmpty: Bool { validation == .empty }
    private var canApply: Bool { validation == .valid && !hasConflict && trimmed != filename }
    private var isIdle: Bool { !isRenamingInProgress && wikilinkRenameCount == nil }
    @FocusState private var isFilenameFocused: Bool
    @State private var filenameSelection: TextSelection?

    private func selectAll() {
        filenameSelection = TextSelection(range: draftFilename.startIndex..<draftFilename.endIndex)
    }

    // Not triggered from `onChange(of: isFilenameFocused)` alone: this TextField is hosted via
    // UIHostingController inside a UITextView (the note body's own text container), and that
    // nested-first-responder setup on iOS leaves `isFilenameFocused` unreliable — on iPhone it can
    // stay stuck at false even while the field visibly has the caret and keyboard, so the
    // Cancel/Apply buttons (gated on `isEditingFilename`) never appeared. A tap gesture is plain
    // UIKit gesture routing, unaffected by that broken SwiftUI focus plumbing, so it's used as the
    // primary "editing started" signal instead. Guarded to fire only once per edit session so a
    // later tap to reposition the cursor doesn't re-select all the text.
    private func beginEditingIfNeeded() {
        guard isIdle, !isEditingFilename else { return }
        isEditingFilename = true
        selectAll()
    }

    private func cancelEdit() {
        guard isIdle else { return }
        draftFilename = filename
        isEditingFilename = false
        isFilenameFocused = false
        // `isFilenameFocused = false` alone doesn't reliably resign the real UITextField here —
        // same nested-hosting FocusState breakage as `beginEditingIfNeeded()` above, just in the
        // write direction. Resigning via the responder chain directly is what actually dismisses
        // the caret/keyboard.
        //
        // Deferred to the next run loop turn: the same tap that hits this Cancel button can also
        // be seen by the underlying note-body UITextView's own tap-to-place-cursor recognizer
        // (another symptom of the header's UIHostingController not being a proper child view
        // controller — see the nested-hosting FocusState memory note), which grabs first responder
        // for the body right after we resign the filename field, landing the cursor there instead
        // of dismissing the keyboard entirely. Resigning after that recognition has settled hits
        // whatever actually ended up first responder, so the keyboard closes for good.
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("", text: $draftFilename, selection: $filenameSelection)
                .textFieldStyle(.plain)
                .font(.title3.bold())
                .disabled(!isIdle)
                .focused($isFilenameFocused)
                .onSubmit { if canApply { onApplyRename() } else { cancelEdit() } }
                .simultaneousGesture(TapGesture().onEnded { beginEditingIfNeeded() })
                .onChange(of: isFilenameFocused) { _, focused in
                    guard focused else { return }
                    beginEditingIfNeeded()
                }
                .overlay(alignment: .bottom) {
                    if hasConflict || isEmpty {
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
            } else if isEditingFilename {
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
        }
    }
}
