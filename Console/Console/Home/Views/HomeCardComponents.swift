import SwiftUI

/// Shared grammar for the four Home dashboard cards
/// (Design/HomeCards/DESIGN_PROMPT.md §3). Every card in every panel puts its
/// attention dot, identity token, title and age in the same place, so these
/// metrics and surfaces live in exactly one place.
enum HomeCardMetrics {
    /// Card padding 9 / 7 / 9 / 8.
    static let padding = EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9)

    /// Gap between the rows inside one card.
    static let rowGap: CGFloat = 3

    /// Gap between cards in a list.
    static let listGap: CGFloat = 4

    /// Corner radius of a single card.
    static let cornerRadius: CGFloat = 6

    /// Minimum card height; grows to content.
    static let minHeight: CGFloat = 44

    /// The permanently reserved trailing action slot on row two. Reserved
    /// even when empty — that is what makes occlusion structurally impossible.
    static let actionSlotWidth: CGFloat = 16

    /// Fixed-width leading slot for the row-one glyph (6pt state dot, or the
    /// 12pt needs-you badge). Reserving the slot keeps the identity text's
    /// x-origin identical whether or not the card needs you
    /// (Design/HomeCards/DESIGN_PROMPT.md §3).
    static let glyphSlotWidth: CGFloat = 12

    // Row-one type ramp.
    static let identityFont = Font.system(size: 10, design: .monospaced)
    static let stateFont = Font.system(size: 10, weight: .medium)
    static let stateEmphasisFont = Font.system(size: 10, weight: .semibold)
    static let ageFont = Font.system(size: 10)
    static let titleFont = Font.system(size: 13, weight: .medium)

    /// Panel header height, one row.
    static let headerHeight: CGFloat = 28
}

extension View {
    /// The shared card surface: `controlBackgroundColor` fill, no stroke,
    /// a persistent one-point inset when `alertInset` is set (needs-you
    /// sessions), and a one-point accent inset on hover.
    func homeCardSurface(
        hovering: Bool,
        alertInset: Color? = nil,
        cornerRadius: CGFloat = HomeCardMetrics.cornerRadius
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
            )
            .overlay {
                let inset: Color?
                if let alertInset {
                    inset = alertInset
                } else if hovering {
                    inset = .accentColor
                } else {
                    inset = nil
                }
                return Group {
                    if let inset {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(inset, lineWidth: 1)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// A trailing slot that is always reserved, whether or not content fills
    /// it. Reserving the space is the point.
    var homeActionSlot: some View {
        frame(width: HomeCardMetrics.actionSlotWidth)
    }
}

/// Panel header owned by each of the four panels: title, then service and
/// count as one quiet run, then icon-only actions. One header per panel,
/// always this exact shape.
struct HomePanelHeader<Detail: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() },
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            detail()

            Spacer(minLength: 4)

            accessory()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: HomeCardMetrics.headerHeight)
        .accessibilityElement(children: .contain)
    }
}

/// Row-one leading glyph shared by the card views: the 6pt state dot, or the
/// red needs-you badge in the same fixed-width slot, so the identity text's
/// leading x is identical in both states (DESIGN_PROMPT.md §3).
struct HomeCardGlyph: View {
    let color: Color
    let needsYou: Bool

    var body: some View {
        Group {
            if needsYou {
                AttentionBadge()
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: HomeCardMetrics.glyphSlotWidth, alignment: .leading)
    }
}

/// The quiet "JIRA · 16" service-and-count run after a header title.
func HomePanelDetail(_ parts: String...) -> some View {
    Text(parts.filter { !$0.isEmpty }.joined(separator: " · "))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
}

/// Light gray age of a source's last successful refresh, rendered as whole
/// elapsed minutes up to `maxStaleMinutes`; anything older (or never
/// refreshed) collapses to a single hourglass symbol. Re-renders each minute.
struct HomeRefreshAgeLabel: View {
    /// Date of the source's last successful extraction; nil renders the
    /// hourglass from the start.
    let lastRefresh: Date?

    static let maxStaleMinutes = 240

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let lastRefresh,
               let minutes = elapsedMinutes(from: lastRefresh, to: context.date),
               minutes <= Self.maxStaleMinutes {
                Text("\(minutes)m")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func elapsedMinutes(from date: Date, to now: Date) -> Int? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return nil }
        return Int(seconds / 60)
    }
}

/// Loading skeleton shaped like the real card: a short bone where the
/// identity goes and a long one where the title goes.
struct HomeSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .quaternarySystemFill))
                .frame(width: 84, height: 8)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .quaternarySystemFill))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeCardMetrics.cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
        )
    }
}
