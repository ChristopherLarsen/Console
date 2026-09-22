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
    /// MR IIDs are project-scoped; compare parsed project identity as well.
    static func reviewSession(for url: URL, in sessions: [ConsoleSession], associations: SessionAssociationStore? = nil) -> ConsoleSession? {
        if let associations,
           let linked = associations.session(for: url, kind: .gitlabMergeRequest, role: .reviewer, in: sessions) {
            return linked
        }
        // Fall back to the session's own MR chip: a missing or unreadable
        // catalog link must not hide a review session the user already has,
        // which would relabel the card "Start Review" and launch a duplicate.
        guard let target = GitLabSourceContext.parseMergeRequest(fromURL: url) else { return nil }
        let matches = sessions.reversed().filter { session in
            session.purpose == .review && session.artifacts.contains { artifact in
                guard artifact.kind == .gitlabMergeRequest, let url = artifact.url,
                      let source = GitLabSourceContext.parseMergeRequest(fromURL: url) else { return false }
                return source.projectIdentity == target.projectIdentity && source.iid == target.iid
            }
        }
        return matches.first { $0.activity != .exited } ?? matches.first
    }

    /// How a Review card can continue a previous review of one merge request.
    enum ReviewResolution: Equatable {
        /// No prior review session: the card starts a new one.
        case none
        /// A live review session is already open.
        case live(UUID)
        /// A saved reviewer conversation (or an exited session) to resume.
        case resumable(SessionRestorationRecord)

        var hasPreviousSession: Bool {
            if case .none = self { return false }
            return true
        }
    }

    /// Resolves the session a Review card should continue: the live review
    /// session when one is open, otherwise the newest saved reviewer
    /// conversation, otherwise an exited session's own identity. Self Review
    /// conversations are skipped — the initial review is a plain review.
    static func reviewResolution(
        for url: URL,
        in sessions: [ConsoleSession],
        associations: SessionAssociationStore? = nil
    ) -> ReviewResolution {
        let matches = reviewSessions(for: url, in: sessions, associations: associations)
        if let live = matches.first(where: { $0.activity != .exited }) {
            return .live(live.id)
        }
        if let associations,
           let newest = associations.reviewConversations(for: url)
               .first(where: { !isSelfReview($0.record.name) }) {
            return .resumable(newest.record)
        }
        if let exited = matches.first {
            return .resumable(SessionRestorationRecord(
                claudeSessionID: exited.claudeSessionID,
                name: exited.name,
                workingDirectory: exited.workingDirectory,
                purpose: exited.purpose ?? .review
            ))
        }
        return .none
    }

    /// Every session in the list linked to this merge request, newest first —
    /// through the catalog link and, as a fallback, through the session's own
    /// MR chip.
    private static func reviewSessions(
        for url: URL,
        in sessions: [ConsoleSession],
        associations: SessionAssociationStore?
    ) -> [ConsoleSession] {
        var matches: [ConsoleSession] = []
        if let associations {
            let ids = associations.conversationIDs(for: url, kind: .gitlabMergeRequest, role: .reviewer)
            matches += sessions.reversed().filter { ids.contains($0.claudeSessionID) }
        }
        if let target = GitLabSourceContext.parseMergeRequest(fromURL: url) {
            matches += sessions.reversed().filter { session in
                session.purpose == .review && session.artifacts.contains { artifact in
                    guard artifact.kind == .gitlabMergeRequest, let artifactURL = artifact.url,
                          let source = GitLabSourceContext.parseMergeRequest(fromURL: artifactURL) else { return false }
                    return source.projectIdentity == target.projectIdentity && source.iid == target.iid
                }
            }
        }
        var seen = Set<UUID>()
        return matches.filter { seen.insert($0.id).inserted }
    }

    private static func isSelfReview(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Self Review")
    }

    static func jiraURL(for session: ConsoleSession, configuredURL: String, reviewItems: [MergeRequestSummary] = []) -> URL? {
        if let artifact = session.artifacts.last(where: { $0.kind == .jiraIssue }) {
            if let url = artifact.url { return url }
            if let key = JiraSourceContext.parseKey(from: artifact.label) {
                return JiraSourceContext.issueURL(key: key, configuredURL: configuredURL)
            }
        }
        let review = reviewItems.first { item in
            reviewSession(for: item.mergeRequestURL, in: [session]) != nil
        }
        guard let key = review?.jiraIssueKey
            ?? review.flatMap({ JiraSourceContext.issueKey(in: $0.title) })
            ?? NewTicketSessionNaming.jiraKey(forDisplayName: session.name)
            ?? JiraSourceContext.issueKey(in: session.name) else { return nil }
        return JiraSourceContext.issueURL(key: key, configuredURL: configuredURL)
    }

    static func sessionID(
        for key: String,
        issueURL: URL?,
        in sessions: [ConsoleSession],
        associations: SessionAssociationStore? = nil
    ) -> UUID? {
        if let associations, let issueURL {
            return associations.session(for: issueURL, kind: .jiraIssue, role: .author, in: sessions)?.id
        }
        var bestID: UUID?
        var bestIsLive = false
        // Scan newest-first so equal-liveness matches keep the latest store
        // order; an older live match still outranks a newer exited one.
        for session in sessions.reversed() {
            let matches = session.artifacts.contains { artifact in
                guard artifact.kind == .jiraIssue else { return false }
                if let artifactURL = artifact.url, let issueURL {
                    guard let identity = WorkArtifact.identity(kind: .jiraIssue, url: artifactURL) else { return artifactURL == issueURL }
                    return identity == WorkArtifact.identity(kind: .jiraIssue, url: issueURL)
                }
                return artifact.label.caseInsensitiveCompare(key) == .orderedSame
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
        in sessions: [ConsoleSession],
        associations: SessionAssociationStore? = nil
    ) -> UUID? {
        sessionID(for: ticket.key, issueURL: ticket.issueURL, in: sessions, associations: associations)
    }
}
