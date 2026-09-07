import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
        let result = Self.arrange(widths: widths, heights: heights, maxWidth: maxWidth, spacing: spacing)
        return (result.size, result.positions)
    }

    /// Row-packing for the flow layout. The reported width runs to the last
    /// item's trailing edge — the inter-item spacing after the final item in a
    /// row is never included.
    static func arrange(
        widths: [CGFloat],
        heights: [CGFloat],
        maxWidth: CGFloat,
        spacing: CGFloat
    ) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for index in widths.indices {
            let width = widths[index]
            if x + width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, heights[index])
            maxX = max(maxX, x + width)
            x += width + spacing
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
