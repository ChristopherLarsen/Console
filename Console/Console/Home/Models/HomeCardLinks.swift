import Foundation

/// Where a Home card's "Open in JIRA" and "Open in GitLab" buttons go. Every
/// card asks this one resolver, so a link Console knows about through any
/// source (a session's chips, the work catalog, the board, the GitLab scans)
/// shows on every card it belongs to. Nil means no link is known; a card then
/// leaves the button out rather than guess.
@MainActor
struct HomeCardLinks {
    var sessions: [ConsoleSession] = []
    var associations: SessionAssociationStore?
    var jiraTickets: [JiraTicketSummary] = []
    var reviewItems: [MergeRequestSummary] = []
    var authoredItems: [AuthoredMRAttention] = []
    var configuredJiraURL = ""

    // MARK: Stories

    /// The story's JIRA page: the board's own link, else built from the key.
    func jira(forStoryKey key: String) -> URL? {
        guard let key = JiraSourceContext.parseKey(from: key) else { return nil }
        if let ticket = jiraTickets.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            return ticket.issueURL
        }
        return JiraSourceContext.issueURL(key: key, configuredURL: configuredJiraURL)
    }

    /// The story's merge request: the one the work catalog links to it, the
    /// story session's chip, the user's own open merge request naming it, a
    /// review-queue item naming it, and last the newest catalog link.
    func mergeRequest(forStoryKey key: String) -> URL? {
        guard let key = JiraSourceContext.parseKey(from: key) else { return nil }
        func isForStory(_ itemKey: String?, _ title: String) -> Bool {
            itemKey.flatMap(JiraSourceContext.parseKey)?.caseInsensitiveCompare(key) == .orderedSame
                || JiraSourceContext.issueKey(in: title)?.caseInsensitiveCompare(key) == .orderedSame
        }
        // An In Progress story's MR is one the user authored, which the
        // review queue never lists.
        let authored = authoredItems.filter { isForStory($0.jiraIssueKey, $0.title) }.map(\.url)

        var linked: [URL] = []
        let issueURL = jira(forStoryKey: key)
        if let associations, let issueURL {
            linked = Array(Set(associations.relatedArtifacts(to: issueURL, kind: .jiraIssue, workKind: .implementation)
                .filter { $0.kind == .gitlabMergeRequest }.compactMap(\.url)))
            if linked.count == 1 { return linked[0] }
        }
        if let id = HomeStorySessionMatcher.sessionID(for: key, issueURL: issueURL, in: sessions, associations: associations),
           let session = sessions.first(where: { $0.id == id }),
           let url = Self.mergeRequest(in: session) {
            return url
        }
        if let url = authored.first(where: linked.contains) ?? authored.first { return url }
        if let item = reviewItems.first(where: { isForStory($0.jiraIssueKey, $0.title) }) {
            return item.mergeRequestURL
        }
        // Several merge requests are linked and none is known to be open:
        // the newest is the best guess.
        return linked.max { (Int($0.lastPathComponent) ?? 0) < (Int($1.lastPathComponent) ?? 0) }
    }

    // MARK: Merge requests

    /// The story a merge request belongs to: the one the work catalog links
    /// to it, the story the merge request itself names, the story of a
    /// session working on it.
    func jira(forMergeRequest url: URL, key: String?, title: String, workKind: WorkItem.Kind) -> URL? {
        let named = key.flatMap(JiraSourceContext.parseKey) ?? JiraSourceContext.issueKey(in: title)
        if let associations {
            let urls = Set(associations.relatedArtifacts(to: url, kind: .gitlabMergeRequest, workKind: workKind)
                .filter { $0.kind == .jiraIssue }
                .compactMap { link -> URL? in
                    guard let url = link.url, JiraSourceContext.parseIssueKey(fromURL: url) != nil else { return nil }
                    return url
                })
            if urls.count == 1 { return urls.first }
            // Several stories are linked: the one the merge request itself
            // names is the right one. With no such match carry on.
            if let named, let match = urls.first(where: {
                JiraSourceContext.parseIssueKey(fromURL: $0)?.caseInsensitiveCompare(named) == .orderedSame
            }) {
                return match
            }
        }
        let session = workKind == .review
            ? HomeStorySessionMatcher.reviewSession(for: url, in: sessions, associations: associations)
            : associations?.session(for: url, kind: .gitlabMergeRequest, role: .author, in: sessions)
        if let session, let url = HomeStorySessionMatcher.jiraURL(for: session, configuredURL: configuredJiraURL) {
            return url
        }
        return named.flatMap(jira(forStoryKey:))
    }

    // MARK: Decisions

    /// Links for an Orchestrator decision card. The session it names comes
    /// first; a decision with no live session, or one whose session lacks a
    /// link, falls back to the story key or `!iid` its own text names.
    func links(for decision: OrchestratorPlan.Decision, session: ConsoleSession?)
        -> (jira: URL?, mergeRequest: URL?) {
        var jira = session.flatMap {
            HomeStorySessionMatcher.jiraURL(for: $0, configuredURL: configuredJiraURL, reviewItems: reviewItems)
        }
        var mergeRequest = session.flatMap(Self.mergeRequest(in:))

        let texts = [decision.title, decision.summary, decision.question].compactMap { $0 }
        let storyKey = jira.flatMap(JiraSourceContext.parseIssueKey(fromURL:))
            ?? texts.lazy.compactMap(JiraSourceContext.issueKey(in:)).first
        if mergeRequest == nil {
            mergeRequest = storyKey.flatMap { self.mergeRequest(forStoryKey: $0) }
                ?? texts.lazy.compactMap(knownMergeRequest(namedIn:)).first
        }
        if jira == nil {
            jira = storyKey.flatMap { self.jira(forStoryKey: $0) }
                ?? mergeRequest.flatMap { url in
                    let item = reviewItems.first { $0.mergeRequestURL == url }
                    return item.flatMap {
                        self.jira(forMergeRequest: url, key: $0.jiraIssueKey, title: $0.title, workKind: .review)
                    }
                }
        }
        return (jira, mergeRequest)
    }

    /// The one merge request Console knows whose `!iid` the text names.
    /// IIDs are per project, so a number shared by two known merge requests
    /// is left alone.
    func knownMergeRequest(namedIn text: String) -> URL? {
        let iids = Set(text.matches(of: /!([1-9][0-9]*)\b/).map { String($0.output.1) })
        guard iids.count == 1, let iid = iids.first else { return nil }
        var known = reviewItems.map(\.mergeRequestURL) + authoredItems.map(\.url)
        known += sessions.flatMap { $0.artifacts.filter { $0.kind == .gitlabMergeRequest }.compactMap(\.url) }
        let matches = Set(known.compactMap { url -> String? in
            guard GitLabSourceContext.parseMergeRequest(fromURL: url).map({ String($0.iid) }) == iid else { return nil }
            return WorkArtifact.identity(kind: .gitlabMergeRequest, url: url)
        })
        guard matches.count == 1, let identity = matches.first else { return nil }
        return URL(string: identity)
    }

    /// The session's most recently linked merge request.
    static func mergeRequest(in session: ConsoleSession) -> URL? {
        session.artifacts.last(where: { $0.kind == .gitlabMergeRequest })?.url
    }
}
