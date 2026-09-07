import Foundation

/// What the Next card wants the user to do, in priority order:
/// 1. Review someone else's merge request.
/// 2. Address reviewer comments on one of our own merge requests.
/// 3. Jump to an agent session that needs attention.
/// 4. Start a new ticket.
enum NextTaskKind: String, Codable, Equatable, Sendable {
    case reviewMergeRequest = "review_mr"
    case addressComments = "address_comments"
    case sessionAttention = "session_attention"
    case ticketWorkflowStep = "ticket_workflow_step"
    case newTicket = "new_ticket"

    var priorityRank: Int {
        switch self {
        case .reviewMergeRequest: return 0
        case .addressComments: return 1
        case .sessionAttention: return 2
        case .ticketWorkflowStep: return 3
        case .newTicket: return 4
        }
    }
}

/// One actionable "next" decision shown on the sidebar card. Produced by the
/// local priority selector from in-process panel snapshots.
struct NextTask: Equatable, Sendable {
    let kind: NextTaskKind
    /// Short imperative headline, e.g. "Review !88 in AntivirusGodot".
    let headline: String
    /// Up to three supporting lines shown under the headline.
    let lines: [String]
    /// Deep link for MR/ticket tasks; nil for session and source-only tasks.
    let targetURL: URL?
    /// Display name for session-attention tasks; nil otherwise. Never used
    /// to select a session — `sessionID` is the stable identity.
    let sessionName: String?
    /// Stable session identity. Missing IDs must not match another session.
    let sessionID: UUID?
    /// Workflow/step UUIDs for tracked Ticket Work recommendations.
    let workflowID: UUID?
    let stepID: UUID?
    /// Where Open should go. Nil only on legacy/parser values; `resolvedOpenTarget` fills in.
    let openTarget: NextOpenTarget?
    /// One stale-data label for the card, or nil when the pick is current.
    let freshnessNote: String?

    init(
        kind: NextTaskKind,
        headline: String,
        lines: [String],
        targetURL: URL? = nil,
        sessionName: String? = nil,
        sessionID: UUID? = nil,
        workflowID: UUID? = nil,
        stepID: UUID? = nil,
        openTarget: NextOpenTarget? = nil,
        freshnessNote: String? = nil
    ) {
        self.kind = kind
        self.headline = headline
        self.lines = lines
        self.targetURL = targetURL
        self.sessionName = sessionName
        self.sessionID = sessionID
        self.workflowID = workflowID
        self.stepID = stepID
        self.openTarget = openTarget
        self.freshnessNote = freshnessNote
    }

    /// Open target for navigation. Parser-built tasks have no `openTarget`;
    /// session tasks without an ID fall back to the Sessions source rather
    /// than matching another session by name.
    var resolvedOpenTarget: NextOpenTarget {
        if let openTarget { return openTarget }
        switch kind {
        case .reviewMergeRequest:
            if let targetURL { return .mergeRequest(url: targetURL, list: .reviewsRequested) }
            return .source(.reviews)
        case .addressComments:
            if let targetURL { return .mergeRequest(url: targetURL, list: .authored) }
            return .source(.authored)
        case .sessionAttention:
            if let sessionID { return .session(id: sessionID) }
            return .source(.sessions)
        case .ticketWorkflowStep:
            if let workflowID, let stepID {
                return .ticketWorkflow(workflowID: workflowID, stepID: stepID)
            }
            return .source(.jira)
        case .newTicket:
            if let targetURL { return .jiraIssue(key: "", url: targetURL) }
            return .source(.jira)
        }
    }
}
