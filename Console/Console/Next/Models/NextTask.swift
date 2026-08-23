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
    case newTicket = "new_ticket"

    var priorityRank: Int {
        switch self {
        case .reviewMergeRequest: return 0
        case .addressComments: return 1
        case .sessionAttention: return 2
        case .newTicket: return 3
        }
    }
}

/// One actionable "next" decision shown on the sidebar card. Produced either
/// by the configured AI provider or by the deterministic local fallback.
struct NextTask: Equatable, Sendable {
    let kind: NextTaskKind
    /// Short imperative headline, e.g. "Review !88 in AntivirusGodot".
    let headline: String
    /// Up to three supporting lines shown under the headline.
    let lines: [String]
    /// Deep link for MR tasks; nil for other kinds.
    let targetURL: URL?
    /// Exact session name for session-attention tasks; nil otherwise.
    let sessionName: String?

    init(
        kind: NextTaskKind,
        headline: String,
        lines: [String],
        targetURL: URL? = nil,
        sessionName: String? = nil
    ) {
        self.kind = kind
        self.headline = headline
        self.lines = lines
        self.targetURL = targetURL
        self.sessionName = sessionName
    }
}
