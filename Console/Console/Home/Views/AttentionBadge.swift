import SwiftUI

/// The one glyph Console uses wherever an item wants the user's attention: a
/// small red circle with a white exclamation mark. A card swaps its 6pt state
/// dot for this badge when the item demands a human, so the leading x stays
/// fixed and red keeps its single meaning ("needs you",
/// Design/HomeCards/DESIGN_PROMPT.md §3).
///
/// Whether an item warrants the badge is decided by `AttentionChannel`
/// (badge predicates live there), never by the card that renders it.
struct AttentionBadge: View {
    /// Point size of the glyph; 12 stays legible beside 10pt card text.
    var pointSize: CGFloat = 12

    /// When set, the badge is its own accessibility element (used where the
    /// surrounding row does not already speak for it). When nil it is hidden
    /// from accessibility because the card's combined label appends
    /// "Needs attention" itself.
    var accessibilityLabel: String? = nil

    var body: some View {
        let glyph = Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: pointSize))
            .foregroundStyle(AttentionChannel.needsYou.color)
        if let accessibilityLabel {
            glyph.accessibilityLabel(accessibilityLabel)
        } else {
            glyph.accessibilityHidden(true)
        }
    }
}

#Preview("Badge") {
    HStack(spacing: 12) {
        AttentionBadge()
        AttentionBadge(pointSize: 13, accessibilityLabel: "Needs attention")
    }
    .padding()
}
