import SwiftUI

/// The single attention channel every Home card renders as its 6pt dot and
/// its tinted state text. One meaning per colour across all four panels
/// (Design/HomeCards/DESIGN_PROMPT.md §3): red means "needs you", orange "in
/// flight", blue "active", green "clear", grey "parked".
///
/// This file is the only place a card decides a state colour. The session
/// column of the table is owned by `DisplayedSessionState` and extended here;
/// ticket statuses and merge-request conditions resolve into the same
/// channels so no card view keeps a private mapping beside it.
enum AttentionChannel: Sendable, Equatable {
    case needsYou
    case inFlight
    case active
    case clear
    case parked

    var color: Color {
        switch self {
        case .needsYou: return .red
        case .inFlight: return .orange
        case .active: return .blue
        case .clear: return .green
        case .parked: return .gray
        }
    }

    // MARK: - Ticket status column

    /// Maps a JIRA status label to its channel. Unfamiliar status vocabulary
    /// parks in grey; the status text itself still renders verbatim.
    static func forTicketStatus(_ status: String?) -> AttentionChannel {
        switch normalized(status) {
        case "blocked":
            return .needsYou
        case "testing", "in review", "code review", "review":
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
    /// failed > blocked > running > draft > passed. The label is what the
    /// host actually rendered (or "Draft"); nil when the host rendered no
    /// state at all.
    static func forMergeRequest(
        isDraft: Bool,
        pipelineDisplayState: String?,
        reviewDisplayState: String?
    ) -> (channel: AttentionChannel, label: String)? {
        // Precedence from §3: failed > blocked > running > draft > passed.
        if let pipeline = nonEmpty(pipelineDisplayState), let channel = urgentConditionChannel(pipeline) {
            return (channel, pipeline)
        }
        if let review = nonEmpty(reviewDisplayState), let channel = urgentConditionChannel(review) {
            return (channel, review)
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
    /// not name one of them.
    private static func urgentConditionChannel(_ state: String) -> AttentionChannel? {
        switch normalized(state) {
        case "failed", "blocked": return .needsYou
        case "running", "pending": return .inFlight
        default: return nil
        }
    }

    /// Host conditions Draft outranks.
    private static func settledConditionChannel(_ state: String) -> AttentionChannel? {
        switch normalized(state) {
        case "passed", "success": return .clear
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
