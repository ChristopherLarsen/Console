import Foundation

/// Resolves the Start Review input into a merge request to review. Accepts a
/// GitLab merge-request URL, a GitLab merge-request number (`!42` or `42`), or
/// a Jira story key (`NMA-1234`) — the last two matched against the shared
/// review scan's currently-open merge requests. Pure and view-free so the
/// launcher, Home, and tests share one resolution rule.
nonisolated enum ReviewLaunchResolver {
    struct Target: Equatable {
        let iid: String
        let title: String?
        let url: URL
        let jiraIssueKey: String?
    }

    /// `candidates` are the current open merge requests from the shared scan,
    /// most urgent first. Returns nil when the input is unrecognized or names
    /// a merge request no candidate matches.
    static func resolve(raw: String, candidates: [MergeRequestSummary]) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. A full GitLab merge-request URL (or deep link).
        if let url = URL(string: trimmed), url.host != nil,
           let parsed = MergeRequestSourceContext.parse(fromURL: url) {
            let match = candidate(matchingURL: url, in: candidates)
            return Target(
                iid: parsed.iid,
                title: match?.title,
                url: url,
                jiraIssueKey: match.flatMap(jiraIssueKey(for:))
            )
        }

        // 2. A GitLab merge-request number: `!1234` or bare `1234`.
        if let iid = mergeRequestNumber(from: trimmed) {
            guard let match = candidates.first(where: { $0.iidText == iid }) else { return nil }
            return target(for: match)
        }

        // 3. A Jira story key: `NMA-1234`.
        if let key = JiraSourceContext.parseKey(from: trimmed) {
            guard let match = candidates.first(where: {
                jiraIssueKey(for: $0)?.caseInsensitiveCompare(key) == .orderedSame
            }) else { return nil }
            return target(for: match)
        }

        return nil
    }

    /// The launch target for one scanned merge request; nil when the scan did
    /// not report its number.
    static func target(for item: MergeRequestSummary) -> Target? {
        guard let iid = item.iidText else { return nil }
        return Target(
            iid: iid,
            title: item.title,
            url: item.mergeRequestURL,
            jiraIssueKey: jiraIssueKey(for: item)
        )
    }

    /// The Jira key a merge request carries, whether the scan reported it
    /// directly or it is embedded in the title.
    static func jiraIssueKey(for item: MergeRequestSummary) -> String? {
        item.jiraIssueKey ?? JiraSourceContext.issueKey(in: item.title)
    }

    private static func mergeRequestNumber(from raw: String) -> String? {
        if let match = raw.firstMatch(of: /^!(\d+)$/) { return String(match.1) }
        if let match = raw.firstMatch(of: /^(\d+)$/) { return String(match.1) }
        return nil
    }

    private static func candidate(
        matchingURL url: URL,
        in candidates: [MergeRequestSummary]
    ) -> MergeRequestSummary? {
        guard let target = GitLabSourceContext.parseMergeRequest(fromURL: url) else { return nil }
        return candidates.first { item in
            guard let source = GitLabSourceContext.parseMergeRequest(fromURL: item.mergeRequestURL) else { return false }
            return source.projectIdentity == target.projectIdentity && source.iid == target.iid
        }
    }
}
