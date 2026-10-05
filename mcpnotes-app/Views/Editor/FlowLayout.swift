import SwiftUI

/// Wrapping horizontal layout: places subviews left-to-right at their ideal size and starts a new
/// row whenever the next one doesn't fit, instead of compressing them like `HStack` does (which
/// squeezed tag capsules until their labels wrapped mid-word). A subview marked with
/// `.flowFillsRemainingWidth(minWidth:)` stretches to the end of its row, wrapping to a new row
/// first if less than `minWidth` is left.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let contentWidth = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        let width = if let proposed = proposal.width, proposed.isFinite { proposed } else { contentWidth }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let subview = subviews[index]
            var x = current.items.isEmpty ? 0 : current.width + horizontalSpacing
            let size: CGSize

            if let fillMinWidth = subview[FlowFillsRemainingWidthKey.self] {
                if !current.items.isEmpty, maxWidth - x < fillMinWidth {
                    rows.append(current)
                    current = Row()
                    x = 0
                }
                let width = maxWidth.isFinite ? max(maxWidth - x, 0) : fillMinWidth
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                size = CGSize(width: width, height: height)
            } else {
                let ideal = subview.sizeThatFits(.unspecified)
                let width = min(ideal.width, maxWidth)
                if !current.items.isEmpty, x + width > maxWidth {
                    rows.append(current)
                    current = Row()
                    x = 0
                }
                // Only a single subview wider than the whole row gets a constrained proposal.
                size = width < ideal.width
                    ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                    : ideal
            }

            current.items.append(Item(index: index, x: x, size: size))
            current.width = x + size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

private struct FlowFillsRemainingWidthKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

extension View {
    /// Inside a `FlowLayout`, stretches this view to the end of its row; wraps it onto a new row
    /// when less than `minWidth` would be left.
    func flowFillsRemainingWidth(minWidth: CGFloat) -> some View {
        layoutValue(key: FlowFillsRemainingWidthKey.self, value: minWidth)
    }
}
