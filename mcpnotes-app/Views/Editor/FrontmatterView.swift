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
    private func cancelEdit() {
        guard isIdle else { return }
        draftFilename = filename
        isEditingFilename = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isEditingFilename {
                    FilenameTextField(
                        text: $draftFilename,
                        shouldFocus: isIdle,
                        isEnabled: isIdle,
                        onSubmit: { if canApply { onApplyRename() } else { cancelEdit() } },
                        onEscape: cancelEdit
                    )

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
        .background(.background.secondary)
    }
}

// MARK: - CursorAtEndTextField

private final class CursorAtEndTextField: NSTextField {
    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        if let editor = currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        }
    }
}

// MARK: - FilenameTextField

private struct FilenameTextField: NSViewRepresentable {
    @Binding var text: String
    var shouldFocus: Bool
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = CursorAtEndTextField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .callout)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEnabled = isEnabled
        if shouldFocus {
            DispatchQueue.main.async {
                guard field.window?.firstResponder !== field.currentEditor() else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilenameTextField

        init(_ parent: FilenameTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            let end = editor.string.count
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
