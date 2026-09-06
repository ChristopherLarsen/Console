import Foundation

/// Value snapshots of the four sources the Next decision draws from, kept
/// free of views, terminals, and WebKit so everything here is unit-testable.
struct NextContextSnapshot: Equatable, Sendable {
    struct SessionInfo: Equatable, Sendable {
        let name: String
        let state: DisplayedSessionState
        let summary: String?

        var needsYou: Bool { HomeSessionsPresentation.needsYou(state) }
    }

    var reviewItems: [MergeRequestSummary] = []
    var authoredItems: [MergeRequestSummary] = []
    var sessions: [SessionInfo] = []
    var tickets: [JiraTicketSummary] = []

    var isEmpty: Bool {
        reviewItems.isEmpty && authoredItems.isEmpty && sessions.isEmpty && tickets.isEmpty
    }
}

/// Pure local rules for the Next card. Picks one task in priority order
/// (review others' MRs, then address comments on our own, then session
/// attention, then start a new ticket). Panel-derived text stays in-process.
enum NextContextBuilder {
    // MARK: - Selection

    /// The next task to show on the card. Always returns something that
    /// points the user somewhere useful. Never packages snapshot text for
    /// an external model.
    static func recommendedTask(for snapshot: NextContextSnapshot) -> NextTask {
        if let item = firstReviewItem(in: snapshot.reviewItems) {
            return NextTask(
                kind: .reviewMergeRequest,
                headline: "Review \(shortTitle(for: item))",
                lines: lines(for: item),
                targetURL: item.mergeRequestURL
            )
        }

        if let item = firstNeedsYouAuthoredItem(in: snapshot.authoredItems) {
            return NextTask(
                kind: .addressComments,
                headline: "Address feedback on \(shortTitle(for: item))",
                lines: lines(for: item),
                targetURL: item.mergeRequestURL
            )
        }

        if let session = snapshot.sessions.first(where: \.needsYou) {
            return NextTask(
                kind: .sessionAttention,
                headline: "\(session.state.label): \(session.name)",
                lines: [summaryLine(for: session)],
                sessionName: session.name
            )
        }

        if let ticket = firstParkedTicket(in: snapshot.tickets) {
            return NextTask(
                kind: .newTicket,
                headline: "Start \(ticket.key)",
                lines: clampedLines(ticket.summary),
                targetURL: ticket.issueURL
            )
        }

        return NextTask(
            kind: .newTicket,
            headline: "Nothing needs you right now",
            lines: [
                snapshot.isEmpty
                    ? "No reviews, MRs, sessions, or tickets found yet."
                    : "Everything visible is already moving.",
                "Pick the next ticket from JIRA to get ahead."
            ]
        )
    }

    private static func firstReviewItem(in items: [MergeRequestSummary]) -> MergeRequestSummary? {
        items.min { $0.sourceOrder < $1.sourceOrder }
    }

    /// Authored MRs whose condition means the author owes work ("Changes
    /// requested", failed pipeline, blocked, discussion) — the same rule that
    /// shows the red badge on My MR cards.
    private static func firstNeedsYouAuthoredItem(in items: [MergeRequestSummary]) -> MergeRequestSummary? {
        items
            .filter { item in
                AttentionChannel.forMergeRequest(
                    isDraft: item.isDraft,
                    pipelineDisplayState: item.pipelineDisplayState,
                    reviewDisplayState: item.reviewDisplayState
                )?.channel == .needsYou
            }
            .min { $0.sourceOrder < $1.sourceOrder }
    }

    /// Backlog / To-Do style tickets — the natural "start something new" pool.
    private static func firstParkedTicket(in tickets: [JiraTicketSummary]) -> JiraTicketSummary? {
        tickets
            .filter { AttentionChannel.forTicketStatus($0.status) == .parked }
            .min { $0.sourceOrder < $1.sourceOrder }
    }

    // MARK: - Copy helpers

    private static func shortTitle(for item: MergeRequestSummary) -> String {
        if let iid = item.iidText, !iid.isEmpty {
            if let project = item.projectDisplayName, !project.isEmpty {
                return "!\(iid) in \(project)"
            }
            return "!\(iid)"
        }
        return item.title
    }

    private static func lines(for item: MergeRequestSummary) -> [String] {
        var result: [String] = []
        if !item.title.isEmpty { result.append(item.title) }
        var conditions: [String] = []
        if item.isDraft { conditions.append("draft") }
        if let pipeline = item.pipelineDisplayState, !pipeline.isEmpty { conditions.append(pipeline) }
        if let review = item.reviewDisplayState, !review.isEmpty { conditions.append(review) }
        if !conditions.isEmpty { result.append(conditions.joined(separator: " · ")) }
        if let updated = item.updatedText, !updated.isEmpty { result.append(updated) }
        return Array(result.prefix(NextTaskResponseParser.maxLines))
    }

    private static func summaryLine(for session: NextContextSnapshot.SessionInfo) -> String {
        guard let summary = session.summary, !summary.isEmpty else {
            return "The agent is blocked without your input."
        }
        return clampedLines(summary)[0]
    }

    private static func clampedLines(_ text: String) -> [String] {
        let limit = NextTaskResponseParser.maxLineLength
        guard text.count > limit else { return [text] }
        return [String(text.prefix(limit - 1)) + "…"]
    }
}
