import SwiftUI

/// Compact native card for one merge request rendered by the active code
/// host's list, drawn to the shared card grammar
/// (Design/HomeCards/DESIGN_PROMPT.md §3).
///
/// Row one: dot + `!iid` identity token + one resolved state + relative age.
/// Row two: title plus a permanently reserved 16pt action slot carrying the
/// open-in-host glyph. Row three (optional): author and project, present only
/// in the reviews-requested list where the author is the routing signal.
/// Unavailable optional fields are omitted entirely — never guessed, never
/// shown as "Unknown". The whole card is one button that opens the captured
/// absolute MR URL in the shared page.
struct MergeRequestCardView: View {
    let item: MergeRequestSummary
    let kind: CodeHostListKind
    let opensInPanel: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: opensInPanel) {
            cardBody
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open merge request in GitLab")
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
            HStack(spacing: 5) {
                // The state dot becomes the red attention badge when this MR
                // demands a human; the leading x never moves.
                if showsAttentionBadge {
                    AttentionBadge()
                } else {
                    Circle()
                        .fill(resolvedChannel.color)
                        .frame(width: 6, height: 6)
                }

                if let iid = item.iidText {
                    Text("!\(iid)")
                        .font(HomeCardMetrics.identityFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let state = resolvedState {
                    Text(state.label)
                        .font(HomeCardMetrics.stateFont)
                        .foregroundStyle(state.channel.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                ageText
            }

            HStack(alignment: .top, spacing: 4) {
                Text(item.title)
                    .font(HomeCardMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.title)

                Spacer(minLength: 2)

                // The reserved action slot carries an explicit open-in-host
                // glyph. A future start-session action on MR cards fits this
                // same slot; the glyph is decoration inside this single card
                // button.
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(hovering ? 1 : 0.3))
                    .homeActionSlot
            }

            if kind == .reviewsRequested {
                contextRow
            }
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        .homeCardSurface(hovering: hovering)
    }

    // MARK: - Fields (omitted cleanly when the host did not render them)

    /// One state per card per the §3 precedence rule:
    /// failed > blocked > running > draft > passed. The label names whatever
    /// the host actually rendered.
    private var resolvedState: (channel: AttentionChannel, label: String)? {
        AttentionChannel.forMergeRequest(
            isDraft: item.isDraft,
            pipelineDisplayState: item.pipelineDisplayState,
            reviewDisplayState: item.reviewDisplayState
        )
    }

    private var resolvedChannel: AttentionChannel {
        resolvedState?.channel ?? .parked
    }

    /// Every row of the reviews-requested list wants Christopher's review;
    /// authored rows only when their resolved condition is needs-you.
    private var showsAttentionBadge: Bool {
        AttentionChannel.mergeRequestWantsBadge(
            kind: kind,
            isDraft: item.isDraft,
            pipelineDisplayState: item.pipelineDisplayState,
            reviewDisplayState: item.reviewDisplayState
        )
    }

    @ViewBuilder
    private var ageText: some View {
        if let age = RelativeAge.compact(from: item.updatedText) {
            Text(age)
                .font(HomeCardMetrics.ageFont.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Author by panel: in reviewsRequested the author is the point — who is
    /// waiting — so author and project share row three. In authored every row
    /// is the same person and the whole third row is dropped.
    private var contextRow: some View {
        Group {
            if let text = contextText {
                HStack(spacing: 5) {
                    if let initials = authorInitials {
                        Text(initials)
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: .quaternarySystemFill))
                            )
                            .accessibilityHidden(true)
                    }

                    Text(text)
                        .font(HomeCardMetrics.identityFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)
                }
            }
        }
    }

    private var contextText: String? {
        var parts: [String] = []
        if let author = item.authorDisplayName { parts.append(author) }
        if let project = item.projectDisplayName { parts.append(project) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var authorInitials: String? {
        guard let name = item.authorDisplayName else { return nil }
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? nil : letters.joined().uppercased()
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.title]
        var context: [String] = []
        if let project = item.projectDisplayName { context.append(project) }
        if let iid = item.iidText { context.append("!\(iid)") }
        if !context.isEmpty { parts.append(context.joined(separator: " · ")) }
        if let author = item.authorDisplayName { parts.append(author) }
        if item.isDraft { parts.append("Draft") }
        if let pipeline = item.pipelineDisplayState { parts.append("Pipeline \(pipeline)") }
        if let updated = item.updatedText { parts.append("updated \(updated)") }
        if showsAttentionBadge { parts.append("Needs attention") }
        return parts.joined(separator: ", ")
    }
}

#Preview("Card") {
    MergeRequestCardView(
        item: MergeRequestSummary(
            id: URL(string: "https://example.com/group/project/-/merge_requests/123")!,
            iidText: "123",
            title: "Fix account recovery navigation crash",
            projectDisplayName: "Console iOS",
            authorDisplayName: "Alex Chen",
            isDraft: false,
            pipelineDisplayState: "Failed",
            reviewDisplayState: nil,
            updatedText: "2h ago",
            mergeRequestURL: URL(string: "https://example.com/group/project/-/merge_requests/123")!,
            sourceOrder: 0
        ),
        kind: .reviewsRequested,
        opensInPanel: {}
    )
    .frame(width: 320)
    .padding()
}
