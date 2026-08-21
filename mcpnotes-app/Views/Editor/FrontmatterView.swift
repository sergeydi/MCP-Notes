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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FilenameEditorView(
                filename: filename,
                draftFilename: $draftFilename,
                isEditingFilename: $isEditingFilename,
                isRenamingInProgress: isRenamingInProgress,
                wikilinkRenameCount: wikilinkRenameCount,
                otherFilenames: otherFilenames,
                onApplyRename: onApplyRename
            )

            Divider()

            TagsEditorView(tags: $tags, allTags: allTags, onChange: onTagsChanged)
        }
        .font(.callout)
        .padding()
        .background(.background)
    }
}
