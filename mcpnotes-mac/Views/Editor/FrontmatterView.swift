import SwiftUI

/// Displays the note's YAML frontmatter as a read-only table.
/// The `uid` row is read-only; the `tags` row allows editing.
struct FrontmatterView: View {
    let uid: UUID
    @Binding var tags: [String]
    let allTags: [String]
    var onTagsChanged: () -> Void

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("uid")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                Text(uid.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .gridColumnAlignment(.leading)
            }

            Divider()
                .gridCellUnsizedAxes(.horizontal)

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
