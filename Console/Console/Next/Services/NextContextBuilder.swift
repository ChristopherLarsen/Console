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

/// Pure rules for the Next card: builds a bounded prompt snapshot and picks
/// the deterministic fallback task in priority order (review others' MRs,
/// then address comments on our own, then session attention, then start a
/// new ticket).
enum NextContextBuilder {
    /// Bounds prompt size; host lists are already ordered by relevance.
    static let maxItemsPerList = 10

    // MARK: - Fallback selection

    /// The deterministic next task when no AI is available or its answer is
    /// unusable. Always returns something pointing the user somewhere useful.
    static func fallbackTask(for snapshot: NextContextSnapshot) -> NextTask {
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

    // MARK: - Prompt text

    /// Compact plain-text rendering of everything the AI may consider.
    static func promptText(for snapshot: NextContextSnapshot) -> String {
        var sections: [String] = []

        if !snapshot.reviewItems.isEmpty {
            sections.append("MRs TO REVIEW (host order):")
            sections.append(
                contentsOf: snapshot.reviewItems.prefix(maxItemsPerList).enumerated().map { index, item in
                    "\(index + 1). \(describe(item))"
                }
            )
        }

        if !snapshot.authoredItems.isEmpty {
            sections.append("MY OPEN MRs (host order):")
            sections.append(
                contentsOf: snapshot.authoredItems.prefix(maxItemsPerList).enumerated().map { index, item in
                    "\(index + 1). \(describe(item))"
                }
            )
        }

        let attentionSessions = snapshot.sessions.filter(\.needsYou)
        if !attentionSessions.isEmpty {
            sections.append("SESSIONS NEEDING ATTENTION:")
            sections.append(
                contentsOf: attentionSessions.prefix(maxItemsPerList).enumerated().map { index, session in
                    var line = "\(index + 1). \"\(session.name)\" — \(session.state.label)"
                    if let summary = session.summary, !summary.isEmpty {
                        line += " — \(summary)"
                    }
                    return line
                }
            )
        }

        if !snapshot.tickets.isEmpty {
            sections.append("TICKETS:")
            sections.append(
                contentsOf: snapshot.tickets.prefix(maxItemsPerList).enumerated().map { index, ticket in
                    var line = "\(index + 1). \(ticket.key) \"\(ticket.summary)\""
                    if let status = ticket.status, !status.isEmpty { line += " (\(status))" }
                    if let priority = ticket.priority, !priority.isEmpty { line += " [priority \(priority)]" }
                    return line
                }
            )
        }

        return sections.isEmpty ? "(no sources available)" : sections.joined(separator: "\n")
    }

    private static func describe(_ item: MergeRequestSummary) -> String {
        var parts: [String] = []
        if let iid = item.iidText, !iid.isEmpty { parts.append("!\(iid)") }
        parts.append("\"\(item.title)\"")
        if let project = item.projectDisplayName, !project.isEmpty { parts.append(project) }
        if let author = item.authorDisplayName, !author.isEmpty { parts.append("by \(author)") }
        if item.isDraft { parts.append("draft") }
        if let pipeline = item.pipelineDisplayState, !pipeline.isEmpty { parts.append("pipeline: \(pipeline)") }
        if let review = item.reviewDisplayState, !review.isEmpty { parts.append("review: \(review)") }
        return parts.joined(separator: " ")
    }
}
