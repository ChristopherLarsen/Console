import Foundation

/// Resolves the GitLab merge request a session should be connected to, and
/// validates a manually entered URL. Memory-only: nothing here is fetched.
@MainActor
enum MergeRequestConnector {
    enum ConnectionError: LocalizedError, Equatable {
        case invalidURL
        case sessionMissing

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Enter a GitLab merge request URL or its number, e.g. https://gitlab.com/group/project/-/merge_requests/42 or 42"
            case .sessionMissing:
                return "The session no longer exists."
            }
        }
    }

    /// Merge-request URLs a session could connect to, discovered from its Jira
    /// ticket: the review scan's open review requests, the authored list, and
    /// the durable catalog's related merge-request links. De-duplicated by
    /// project + IID, in discovery order.
    static func candidates(
        for session: ConsoleSession,
        associations: SessionAssociationStore?,
        reviewItems: [MergeRequestSummary],
        authoredItems: [AuthoredMRAttention]
    ) -> [URL] {
        var urls: [URL] = []
        if let key = sessionJiraKey(session) {
            urls += reviewItems.filter { matches(key, key: $0.jiraIssueKey, title: $0.title) }
                .map(\.mergeRequestURL)
            urls += authoredItems.filter { matches(key, key: $0.jiraIssueKey, title: $0.title) }
                .map(\.url)
        }
        if let associations, let issueURL = sessionJiraURL(session) {
            for kind in [WorkItem.Kind.implementation, .review] {
                urls += associations.relatedArtifacts(to: issueURL, kind: .jiraIssue, workKind: kind)
                    .filter { $0.kind == .gitlabMergeRequest }
                    .compactMap(\.url)
            }
        }
        var seen = Set<String>()
        return urls.filter { url in
            guard let identity = mergeRequestIdentity(url) else { return false }
            return seen.insert(identity).inserted
        }
    }

    /// Validates a typed merge-request URL. Nil for anything that is not a
    /// GitLab merge request.
    static func mergeRequestURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              GitLabSourceContext.parseMergeRequest(fromURL: url) != nil else { return nil }
        return url
    }

    /// Resolves manually entered input, detecting its type: a full
    /// merge-request URL is used verbatim; a bare or `!`-prefixed number is
    /// matched against `candidates`, then — failing a match — built into the
    /// first candidate's project so a freshly opened merge request in the same
    /// project still attaches. Nil when neither form resolves.
    static func resolveMergeRequestURL(from raw: String, candidates: [URL]) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = mergeRequestURL(from: trimmed) { return url }
        guard let iid = mergeRequestNumber(from: trimmed) else { return nil }
        for candidate in candidates {
            if let info = GitLabSourceContext.parseMergeRequest(fromURL: candidate), info.iid == iid {
                return candidate
            }
        }
        guard let projectURL = candidates.first
            .flatMap(GitLabSourceContext.parseMergeRequest(fromURL:))?.projectURL else { return nil }
        return mergeRequestURL(iid: iid, inProject: projectURL)
    }

    /// Builds `https://host/project/-/merge_requests/<iid>` from a project URL.
    static func mergeRequestURL(iid: String, inProject projectURL: URL) -> URL? {
        guard var components = URLComponents(url: projectURL, resolvingAgainstBaseURL: false),
              !projectURL.path.isEmpty else { return nil }
        let base = projectURL.path.hasSuffix("/") ? String(projectURL.path.dropLast()) : projectURL.path
        components.path = base + "/-/merge_requests/\(iid)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// A typed merge-request number: `1234` or `!1234`; nil for anything else.
    private static func mergeRequestNumber(from raw: String) -> String? {
        if let match = raw.firstMatch(of: /^!(\d+)$/) { return String(match.1) }
        if let match = raw.firstMatch(of: /^(\d+)$/) { return String(match.1) }
        return nil
    }

    /// Project identity + IID, the key that distinguishes one merge request
    /// from another across a project's many.
    static func mergeRequestIdentity(_ url: URL) -> String? {
        guard let info = GitLabSourceContext.parseMergeRequest(fromURL: url) else { return nil }
        return "\(info.projectIdentity)#\(info.iid)"
    }

    // MARK: - Session ticket context

    /// The session's Jira story key: from a `.jiraIssue` artifact first, then
    /// from the session name (a full key, or the legacy `S-1234` display form).
    static func sessionJiraKey(_ session: ConsoleSession) -> String? {
        for artifact in session.artifacts where artifact.kind == .jiraIssue {
            if let url = artifact.url, let key = JiraSourceContext.parseIssueKey(fromURL: url) { return key }
            if let key = JiraSourceContext.parseKey(from: artifact.label) { return key }
        }
        if let key = NewTicketSessionNaming.jiraKey(forDisplayName: session.name) { return key }
        return JiraSourceContext.issueKey(in: session.name)
    }

    /// The session's Jira issue URL, for catalog lookups. Prefers a linked
    /// artifact URL; otherwise the key is resolved against the configured site.
    static func sessionJiraURL(_ session: ConsoleSession,
                               configuredURL: String? = UserDefaults.standard.string(forKey: "webViewJiraURL")) -> URL? {
        for artifact in session.artifacts where artifact.kind == .jiraIssue {
            if let url = artifact.url { return url }
            if let key = JiraSourceContext.parseKey(from: artifact.label),
               let configuredURL, let url = JiraSourceContext.issueURL(key: key, configuredURL: configuredURL) {
                return url
            }
        }
        guard let key = sessionJiraKey(session), let configuredURL else { return nil }
        return JiraSourceContext.issueURL(key: key, configuredURL: configuredURL)
    }

    private static func matches(_ key: String, key candidateKey: String?, title: String) -> Bool {
        if let candidateKey,
           JiraSourceContext.normalizedConsoleKey(candidateKey).caseInsensitiveCompare(key) == .orderedSame {
            return true
        }
        return JiraSourceContext.issueKey(in: title)?.caseInsensitiveCompare(key) == .orderedSame
    }
}
