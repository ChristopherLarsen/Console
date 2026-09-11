import SwiftUI

/// The single attention channel every Home card renders as its 6pt dot and
/// its tinted state text. One meaning per colour across all four panels
/// (Design/HomeCards/DESIGN_PROMPT.md §3): red means "needs you", orange "in
/// flight", blue "active", dark green "testing", green "clear", grey "parked".
///
/// This file is the only place a card decides a state colour. The session
/// column of the table is owned by `DisplayedSessionState` and extended here;
/// ticket statuses and merge-request conditions resolve into the same
/// channels so no card view keeps a private mapping beside it.
enum AttentionChannel: Sendable, Equatable {
    case needsYou
    case inFlight
    case testing
    case active
    case clear
    case parked

    /// Dark green (#006400) for the testing channel; the rest use system
    /// palette colours.
    static let testingColor = Color(red: 0, green: 0.392, blue: 0)

    var color: Color {
        switch self {
        case .needsYou: return .red
        case .inFlight: return .orange
        case .testing: return Self.testingColor
        case .active: return .blue
        case .clear: return .green
        case .parked: return .gray
        }
    }

    /// Card-surface fill when the testing channel applies: light green
    /// (#E5FFE5); nil keeps the shared control-background surface.
    static let testingCardFill = Color(red: 229.0 / 255.0, green: 1, blue: 229.0 / 255.0)

    // MARK: - Ticket status column

    /// Maps a JIRA status label to its channel. Unfamiliar status vocabulary
    /// parks in grey; the status text itself still renders verbatim.
    static func forTicketStatus(_ status: String?) -> AttentionChannel {
        switch normalized(status) {
        case "blocked":
            return .needsYou
        case "testing":
            return .testing
        case "in review", "code review", "review":
            return .inFlight
        case "in progress", "in development":
            return .active
        case "done", "resolved", "closed", "completed":
            return .clear
        default:
            // Backlog / To Do / Open and anything unrecognized: present but
            // not asking for anything.
            return .parked
        }
    }

    // MARK: - Merge-request condition column

    /// One state per MR card, resolved with the precedence rule from §3:
    /// failed > blocked > running > draft > passed. Conditions resolve by
    /// rank, not by which side of the card rendered them: a human-blocking
    /// review ("Changes requested") outranks a merely moving pipeline
    /// ("Running"), and the label is what the host actually rendered (or
    /// "Draft"); nil when the host rendered no state at all.
    static func forMergeRequest(
        isDraft: Bool,
        pipelineDisplayState: String?,
        reviewDisplayState: String?
    ) -> (channel: AttentionChannel, label: String)? {
        // Precedence from §3: needs-you conditions > in-flight > draft >
        // settled. Within one rank the pipeline label wins for stability.
        if let pipeline = nonEmpty(pipelineDisplayState), urgentConditionChannel(pipeline) == .needsYou {
            return (.needsYou, pipeline)
        }
        if let review = nonEmpty(reviewDisplayState), urgentConditionChannel(review) == .needsYou {
            return (.needsYou, review)
        }
        if let pipeline = nonEmpty(pipelineDisplayState), urgentConditionChannel(pipeline) == .inFlight {
            return (.inFlight, pipeline)
        }
        if let review = nonEmpty(reviewDisplayState), urgentConditionChannel(review) == .inFlight {
            return (.inFlight, review)
        }
        if isDraft {
            return (.parked, "Draft")
        }
        if let pipeline = nonEmpty(pipelineDisplayState), let channel = settledConditionChannel(pipeline) {
            return (channel, pipeline)
        }
        if let review = nonEmpty(reviewDisplayState), let channel = settledConditionChannel(review) {
            return (channel, review)
        }
        return nil
    }

    /// Host conditions that outrank Draft. Returns nil when the string does
    /// not name one of them. "Changes requested" is the review state that
    /// means the author still owes work, so it reads as needs-you.
    private static func urgentConditionChannel(_ state: String) -> AttentionChannel? {
        switch normalized(state) {
        case "failed", "blocked", "changes requested", "discussion": return .needsYou
        case "running", "pending": return .inFlight
        default: return nil
        }
    }

    /// Review-column helper: a host-rendered review state meaning the author
    /// still owes changes, normalized to the two display labels Console
    /// understands. Console cannot confirm who left the review — callers must
    /// disclose that limitation, never claim "reviewed by you".
    static func awaitingAuthorReviewState(
        _ reviewDisplayState: String?
    ) -> (label: String, channel: AttentionChannel)? {
        guard nonEmpty(reviewDisplayState) != nil else { return nil }
        switch normalized(reviewDisplayState) {
        case "changes requested": return ("Changes requested", .needsYou)
        case "discussion": return ("Discussion", .needsYou)
        default: return nil
        }
    }

    // MARK: - Red attention badge

    /// Whether one JIRA ticket warrants the red badge: High/Highest priority,
    /// or a blocked status.
    static func ticketWantsBadge(priority: String?, status: String?) -> Bool {
        switch normalized(priority) {
        case "high", "highest":
            return true
        default:
            break
        }
        return forTicketStatus(status) == .needsYou
    }

    /// Whether one merge request warrants the red badge. Every row of the
    /// reviews-requested list wants Christopher's review by definition; an
    /// authored row only when its resolved condition is needs-you (failed
    /// pipeline, blocked, or changes requested).
    static func mergeRequestWantsBadge(
        kind: CodeHostListKind,
        isDraft: Bool,
        pipelineDisplayState: String?,
        reviewDisplayState: String?
    ) -> Bool {
        switch kind {
        case .reviewsRequested:
            return true
        case .authored:
            return forMergeRequest(
                isDraft: isDraft,
                pipelineDisplayState: pipelineDisplayState,
                reviewDisplayState: reviewDisplayState
            )?.channel == .needsYou
        }
    }

    /// Host conditions Draft outranks. The pipeline vocabulary is CI-native
    /// ("passed"/"success"); the review side adds GitLab's approval state so
    /// host-rendered review text the host actually settled on still becomes
    /// card state instead of disappearing.
    private static func settledConditionChannel(_ state: String) -> AttentionChannel? {
        switch normalized(state) {
        case "passed", "success", "approved": return .clear
        default: return nil
        }
    }
}

// MARK: - Session column (owned by DisplayedSessionState)

extension DisplayedSessionState {
    /// The session column of the shared colour table.
    var attentionChannel: AttentionChannel {
        switch self {
        case .needsApproval, .needsInput, .blocked, .needsReview, .error:
            return .needsYou
        case .working:
            return .active
        case .done:
            return .clear
        case .idle, .starting, .exited, .unknown:
            return .parked
        }
    }
}

// MARK: - Helpers

private func normalized(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
}

private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
