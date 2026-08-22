import Foundation

/// Pure presentation rules for the Home Sessions radar (CONSOLE_PANEL_2_SESSIONS.md).
/// Sort, "needs you" counting, and subtitle rules live here so they can be
/// unit-tested without launching the app.
enum HomeSessionsPresentation {
    /// Attention-sorted copy of the store's sessions: displayed-state priority
    /// ascending (Needs Approval / Needs Input first, Exited last), with the
    /// store's own order as a stable tie-break. Never re-sorts alphabetically.
    static func sorted(_ sessions: [ConsoleSession]) -> [ConsoleSession] {
        sessions.enumerated().sorted { lhs, rhs in
            let lhsRank = displayedSessionState(
                activity: lhs.element.activity,
                attention: lhs.element.attention
            ).priorityRank
            let rhsRank = displayedSessionState(
                activity: rhs.element.activity,
                attention: rhs.element.attention
            ).priorityRank
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    /// Count of sessions that block the agent and therefore need a human.
    /// Done is deliberately excluded — it is a "look when ready" state.
    static func needsYouCount(in sessions: [ConsoleSession]) -> Int {
        sessions.filter {
            needsYou(displayedSessionState(activity: $0.activity, attention: $0.attention))
        }.count
    }

    /// True for states that block the agent: Needs Approval / Needs Input,
    /// Blocked / Needs Review, and Error. Done is visible but not counted.
    static func needsYou(_ state: DisplayedSessionState) -> Bool {
        switch state {
        case .needsApproval, .needsInput, .blocked, .needsReview, .error:
            return true
        case .done, .working, .idle, .starting, .exited, .unknown:
            return false
        }
    }

    /// One-line subtitle: the summary if present; else the working-folder
    /// basename when it differs from the session name; else omitted so no
    /// folder line merely repeats the name.
    static func subtitle(for session: ConsoleSession) -> String? {
        if let summary = session.summary, !summary.isEmpty {
            return summary
        }
        let folder = session.workingDirectory.lastPathComponent
        guard !folder.isEmpty, folder != session.name else { return nil }
        return folder
    }

    /// Up to two artifact chips plus an overflow count, matching SessionInfoStrip.
    static func artifactChips(for session: ConsoleSession) -> (chips: [SessionArtifact], overflow: Int) {
        let maxVisibleChips = 2
        return (
            chips: Array(session.artifacts.suffix(maxVisibleChips)),
            overflow: max(0, session.artifacts.count - maxVisibleChips)
        )
    }
}
