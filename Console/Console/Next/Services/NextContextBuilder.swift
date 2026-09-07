import Foundation

/// Value snapshots of the four sources the Next decision draws from, kept
/// free of views, terminals, and WebKit so everything here is unit-testable.
struct NextContextSnapshot: Equatable, Sendable {
    struct SessionInfo: Equatable, Sendable {
        let id: UUID
        let name: String
        let state: DisplayedSessionState
        let summary: String?

        var needsYou: Bool { HomeSessionsPresentation.needsYou(state) }

        init(
            id: UUID = UUID(),
            name: String,
            state: DisplayedSessionState,
            summary: String? = nil
        ) {
            self.id = id
            self.name = name
            self.state = state
            self.summary = summary
        }
    }

    /// Actionable tracked-workflow steps (UUIDs only in navigation targets).
    struct WorkflowStepInfo: Equatable, Sendable {
        let workflowID: UUID
        let stepID: UUID
        let stageDisplayName: String
        let stepTitle: String
        let isBlocked: Bool
    }

    var reviewItems: [MergeRequestSummary] = []
    var authoredItems: [MergeRequestSummary] = []
    var sessions: [SessionInfo] = []
    var tickets: [JiraTicketSummary] = []
    var workflowSteps: [WorkflowStepInfo] = []

    var reviewsStatus: NextSourceStatus = .current
    var authoredStatus: NextSourceStatus = .current
    var ticketsStatus: NextSourceStatus = .current
    var sessionsStatus: NextSourceStatus = .current

    var isEmpty: Bool {
        reviewItems.isEmpty && authoredItems.isEmpty && sessions.isEmpty
            && tickets.isEmpty && workflowSteps.isEmpty
    }

    var liveSessionStates: [UUID: DisplayedSessionState] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
    }
}

/// Pure local rules for the Next card. Picks one task in priority order
/// (review others' MRs, then address comments on our own, then session
/// attention, then start a new ticket). Panel-derived text stays in-process.
enum NextContextBuilder {
    static let staleLabel = "Showing previous results"

    // MARK: - Selection

    /// The next task to show on the card. Always returns something that
    /// points the user somewhere useful. Never packages snapshot text for
    /// an external model.
    static func recommendedTask(for snapshot: NextContextSnapshot) -> NextTask {
        if let item = firstReviewItem(in: snapshot.reviewItems) {
            return mergeRequestTask(
                kind: .reviewMergeRequest,
                headline: "Review \(shortTitle(for: item))",
                item: item,
                list: .reviewsRequested,
                freshness: freshnessNote(for: snapshot.reviewsStatus)
            )
        }

        if let item = firstNeedsYouAuthoredItem(in: snapshot.authoredItems) {
            return mergeRequestTask(
                kind: .addressComments,
                headline: "Address feedback on \(shortTitle(for: item))",
                item: item,
                list: .authored,
                freshness: freshnessNote(for: snapshot.authoredStatus)
            )
        }

        if let session = snapshot.sessions.first(where: \.needsYou) {
            return NextTask(
                kind: .sessionAttention,
                headline: "\(session.state.label): \(session.name)",
                lines: [summaryLine(for: session)],
                sessionName: session.name,
                sessionID: session.id,
                openTarget: .session(id: session.id)
            )
        }

        if let step = snapshot.workflowSteps.first(where: { !$0.isBlocked }) {
            return NextTask(
                kind: .ticketWorkflowStep,
                headline: "Continue \(step.stageDisplayName)",
                lines: [step.stepTitle],
                workflowID: step.workflowID,
                stepID: step.stepID,
                openTarget: .ticketWorkflow(workflowID: step.workflowID, stepID: step.stepID)
            )
        }

        if let ticket = firstNeedsYouTicket(in: snapshot.tickets) {
            return NextTask(
                kind: .newTicket,
                headline: "Unblock \(ticket.key)",
                lines: blockedTicketLines(ticket),
                targetURL: ticket.issueURL,
                openTarget: .jiraIssue(key: ticket.key, url: ticket.issueURL),
                freshnessNote: freshnessNote(for: snapshot.ticketsStatus)
            )
        }

        if let ticket = firstParkedTicket(in: snapshot.tickets) {
            return NextTask(
                kind: .newTicket,
                headline: "Start \(ticket.key)",
                lines: clampedLines(ticket.summary),
                targetURL: ticket.issueURL,
                openTarget: .jiraIssue(key: ticket.key, url: ticket.issueURL),
                freshnessNote: freshnessNote(for: snapshot.ticketsStatus)
            )
        }

        return idleTask(for: snapshot)
    }

    // MARK: - Empty / unavailable

    /// Unqualified all-clear is only allowed when every remote source was
    /// actually checked. Signed-out, unconfigured, and failed sources say so.
    private static func idleTask(for snapshot: NextContextSnapshot) -> NextTask {
        let blocked = unavailableSources(in: snapshot)
        if !blocked.isEmpty {
            return NextTask(
                kind: .newTicket,
                headline: "Could not check these sources",
                lines: unavailableLines(for: blocked),
                openTarget: .source(blocked[0].kind),
                freshnessNote: nil
            )
        }

        return NextTask(
            kind: .newTicket,
            headline: "No work in the loaded lists",
            lines: [
                "Nothing in the loaded reviews, MRs, sessions, or tickets needs you.",
                "Open JIRA to pick something new."
            ],
            openTarget: .source(.jira),
            freshnessNote: idleFreshnessNote(for: snapshot)
        )
    }

    private struct UnavailableSource {
        let kind: NextSourceKind
        let status: NextSourceStatus
    }

    private static func unavailableSources(in snapshot: NextContextSnapshot) -> [UnavailableSource] {
        var result: [UnavailableSource] = []
        if snapshot.reviewsStatus.couldNotCheck {
            result.append(UnavailableSource(kind: .reviews, status: snapshot.reviewsStatus))
        }
        if snapshot.authoredStatus.couldNotCheck {
            result.append(UnavailableSource(kind: .authored, status: snapshot.authoredStatus))
        }
        if snapshot.ticketsStatus.couldNotCheck {
            result.append(UnavailableSource(kind: .jira, status: snapshot.ticketsStatus))
        }
        return result
    }

    private static func unavailableLines(for sources: [UnavailableSource]) -> [String] {
        Array(sources.map { sourceLine($0) }.prefix(NextTaskResponseParser.maxLines))
    }

    private static func sourceLine(_ source: UnavailableSource) -> String {
        let name: String
        switch source.kind {
        case .reviews: name = "Reviews"
        case .authored: name = "My MRs"
        case .jira: name = "JIRA"
        case .sessions: name = "Sessions"
        }
        switch source.status.check {
        case .unconfigured:
            return "\(name) is not configured."
        case .signedOut:
            return "\(name) needs sign-in."
        case .failed:
            return "Could not read \(name)."
        case .pending:
            return "\(name) is still loading."
        case .unsupported:
            return "\(name) is not showing a list."
        case .current, .stale:
            return "\(name) could not be checked."
        }
    }

    private static func idleFreshnessNote(for snapshot: NextContextSnapshot) -> String? {
        if snapshot.reviewsStatus.isStale || snapshot.authoredStatus.isStale || snapshot.ticketsStatus.isStale {
            return staleLabel
        }
        return nil
    }

    private static func freshnessNote(for status: NextSourceStatus) -> String? {
        status.isStale ? staleLabel : nil
    }

    private static func mergeRequestTask(
        kind: NextTaskKind,
        headline: String,
        item: MergeRequestSummary,
        list: CodeHostListKind,
        freshness: String?
    ) -> NextTask {
        NextTask(
            kind: kind,
            headline: headline,
            lines: lines(for: item),
            targetURL: item.mergeRequestURL,
            openTarget: .mergeRequest(url: item.mergeRequestURL, list: list),
            freshnessNote: freshness
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

    /// Blocked tickets the user owes attention — they must reach the Next
    /// card, otherwise a loaded list with only blocked work reads as an
    /// unqualified all-clear.
    private static func firstNeedsYouTicket(in tickets: [JiraTicketSummary]) -> JiraTicketSummary? {
        tickets
            .filter { AttentionChannel.forTicketStatus($0.status) == .needsYou }
            .min { $0.sourceOrder < $1.sourceOrder }
    }

    // MARK: - Copy helpers

    /// Status plus truncated summary for a blocked-ticket task card.
    private static func blockedTicketLines(_ ticket: JiraTicketSummary) -> [String] {
        var lines: [String] = []
        if let status = ticket.status, !status.isEmpty {
            lines.append(status)
        }
        if !ticket.summary.isEmpty {
            lines.append(contentsOf: clampedLines(ticket.summary))
        }
        return lines
    }

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
