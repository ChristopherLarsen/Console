import Foundation

/// Pure match between one Jira story and the user's terminal sessions. A
/// session is associated with a story when it carries a `.jiraIssue` artifact
/// whose label is the ticket key or whose URL is the issue URL — exactly what
/// `SessionLaunchCoordinator.beginJiraTicketLaunch` seeds at creation.
///
/// Ambiguity rule: prefer non-exited sessions; among equals the latest session
/// in store order wins (the array is creation order; ConsoleSession has no
/// timestamp). Multiple matches never substitute a different story.
@MainActor
enum HomeStorySessionMatcher {
    static func sessionID(
        for key: String,
        issueURL: URL?,
        in sessions: [ConsoleSession]
    ) -> UUID? {
        var bestID: UUID?
        var bestIsLive = false
        // Scan newest-first so equal-liveness matches keep the latest store
        // order; an older live match still outranks a newer exited one.
        for session in sessions.reversed() {
            let matches = session.artifacts.contains { artifact in
                guard artifact.kind == .jiraIssue else { return false }
                let labelMatches = artifact.label.caseInsensitiveCompare(key) == .orderedSame
                let urlMatches = issueURL != nil && artifact.url == issueURL
                return labelMatches || urlMatches
            }
            guard matches else { continue }
            let isLive = session.activity != .exited
            if bestID == nil || (isLive && !bestIsLive) {
                bestID = session.id
                bestIsLive = isLive
            }
        }
        return bestID
    }

    /// Convenience for a whole ticket summary.
    static func sessionID(
        for ticket: JiraTicketSummary,
        in sessions: [ConsoleSession]
    ) -> UUID? {
        sessionID(for: ticket.key, issueURL: ticket.issueURL, in: sessions)
    }
}
