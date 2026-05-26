import SwiftUI

/// Displays the note's YAML frontmatter as a read-only table.
/// The `tags` row allows editing.
struct FrontmatterView: View {
    @Binding var tags: [String]
    let allTags: [String]
    var onTagsChanged: () -> Void

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("tags")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                TagsEditorView(tags: $tags, allTags: allTags, onChange: onTagsChanged)
                    .gridColumnAlignment(.leading)
            }
        }
        .font(.callout)
        .padding()
        .background(.background.secondary)
    }
}
