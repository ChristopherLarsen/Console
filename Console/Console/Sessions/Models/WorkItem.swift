import Foundation

/// A durable activity, not a terminal process or a remote issue's status.
struct WorkItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case implementation, review, unspecified }
    let id: UUID
    var kind: Kind
    var title: String
    var artifacts: [WorkArtifact]
    var sessions: [WorkSessionLink]
}

struct WorkSessionLink: Codable, Equatable {
    enum Role: String, Codable { case author, reviewer, related }
    let conversationID: UUID
    var role: Role
}

/// External identity is separate from the label used by artifact chips.
/// Legacy key-only tickets remain unscoped and never merge across conversations.
struct WorkArtifact: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: SessionArtifactKind
    let identity: String?
    var label: String
    var url: URL?

    init(_ artifact: SessionArtifact) {
        id = artifact.id
        kind = artifact.kind
        label = artifact.label
        url = artifact.url
        identity = Self.identity(kind: artifact.kind, url: artifact.url)
    }

    var chip: SessionArtifact {
        SessionArtifact(id: id, kind: kind, label: label, url: url)
    }

    var ticketKey: String? {
        guard kind == .jiraIssue else { return nil }
        return url.flatMap(JiraSourceContext.parseIssueKey) ?? JiraSourceContext.parseKey(from: label)
    }

    static func identity(kind: SessionArtifactKind, url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.query = nil
        parts.fragment = nil
        switch kind {
        case .gitlabMergeRequest:
            guard let canonical = parts.url,
                  MergeRequestSourceContext.launchSource(forURL: canonical, pageTitle: nil) != nil,
                  let match = parts.path.firstMatch(of: /\/-\/merge_requests\/([1-9][0-9]*)(?=\/|$)/)
            else { return nil }
            parts.path = String(parts.path[..<match.range.upperBound])
            return parts.url?.absoluteString
        case .jiraIssue:
            // Reuse the browser's cloud/self-hosted URL rules, including board
            // deep links and selectedIssue query parameters.
            guard let key = JiraSourceContext.parseIssueKey(fromURL: url), let siteURL = parts.url else { return nil }
            return JiraSourceContext.issueURL(key: key, configuredURL: siteURL.absoluteString)?.absoluteString
        }
    }

    func represents(_ other: WorkArtifact) -> Bool {
        guard kind == other.kind else { return false }
        if let identity, let otherID = other.identity { return identity == otherID }
        return identity == nil && other.identity == nil && url == other.url
            && label.caseInsensitiveCompare(other.label) == .orderedSame
    }
}
