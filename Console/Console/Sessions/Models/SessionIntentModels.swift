import Foundation

/// Why a session exists. Drives generated names, icons, remembered
/// workspace choices, and whether an automatic starter prompt applies.
enum SessionPurpose: String, Codable, CaseIterable {
    case newTicket
    case existingTicket
    case review
    case general

    var displayName: String {
        switch self {
        case .newTicket: return "New Ticket"
        case .existingTicket: return "Existing Ticket"
        case .review: return "Review"
        case .general: return "General"
        }
    }

    var intentDescription: String {
        switch self {
        case .newTicket:
            return "Clean, idle Claude session for starting new ticket work."
        case .existingTicket:
            return "Jira-aware session with an automatic starter prompt."
        case .review:
            return "Merge-request review with a read-only review prompt."
        case .general:
            return "Clean, idle Claude session for anything else."
        }
    }

    var symbolName: String {
        switch self {
        case .newTicket: return "plus.square.dashed"
        case .existingTicket: return "ticket"
        case .review: return "eye"
        case .general: return "terminal"
        }
    }

    /// Automatic session-name base when the user supplies no override.
    func defaultName(source: SessionLaunchSource?) -> String {
        switch self {
        case .newTicket: return "New Ticket"
        case .general: return "General"
        case .existingTicket:
            if case let .jira(key, _, _) = source { return key }
            return "Existing Ticket"
        case .review:
            if case let .mergeRequest(iid, _, _) = source {
                return "Review !\(iid)"
            }
            return "Review"
        }
    }
}

/// Memory-only context about the Jira ticket or GitLab merge request a
/// launch came from. Never persisted and never leaves the process.
nonisolated enum SessionLaunchSource: Equatable, Sendable {
    case jira(key: String, title: String?, url: URL?)
    case mergeRequest(iid: String, title: String?, url: URL)

    /// Stable routing identity used for hashed workspace associations.
    /// Titles are deliberately excluded. The identity is derived from the
    /// URL shape, so associations keep resolving even if the stored host tag
    /// and the URL disagree.
    var routingIdentity: String? {
        switch self {
        case let .jira(key, _, _):
            return JiraSourceContext.projectKeyPrefix(of: key)?.uppercased()
        case let .mergeRequest(_, _, url):
            return MergeRequestSourceContext.projectIdentity(inURL: url)
        }
    }

    var artifactLabel: String {
        switch self {
        case let .jira(key, _, _): return key
        case let .mergeRequest(iid, _, _): return "MR !\(iid)"
        }
    }

    var artifactKind: SessionArtifactKind {
        switch self {
        case .jira: return .jiraIssue
        case .mergeRequest: return .gitlabMergeRequest
        }
    }

    var artifactURL: URL? {
        switch self {
        case let .jira(_, _, url): return url
        case let .mergeRequest(_, _, url): return url
        }
    }
}

/// Everything needed to build and launch one session.
struct SessionCreationRequest {
    let purpose: SessionPurpose
    let name: String
    let workingDirectory: URL
    let source: SessionLaunchSource?
    let starterPrompt: String?

    init(
        purpose: SessionPurpose,
        name: String,
        workingDirectory: URL,
        source: SessionLaunchSource? = nil,
        starterPrompt: String? = nil
    ) {
        self.purpose = purpose
        self.name = name
        self.workingDirectory = workingDirectory
        self.source = source
        self.starterPrompt = starterPrompt
    }
}

/// A user-configured local folder sessions can open in. This is the only
/// launch-related state that persists.
struct SessionWorkspace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var directoryPath: String

    init(id: UUID = UUID(), name: String, directoryPath: String) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
    }

    var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }
}

// MARK: - Source context parsing (memory-only)

/// Parses Jira keys and URLs out of strings the retained WebView already
/// rendered. Results live only in memory.
nonisolated enum JiraSourceContext {
    /// Uppercase project prefix of a key like `ENG-123` → `ENG`.
    static func projectKeyPrefix(of key: String) -> String? {
        guard let match = key.firstMatch(of: /^([A-Za-z][A-Za-z0-9]*)-\d+$/) else { return nil }
        return String(match.1).uppercased()
    }

    /// Accepts a bare issue key (`ENG-123`) or a Jira issue URL
    /// (`…/browse/ENG-123`, `…/issues/ENG-123`, `?selectedIssue=ENG-123`).
    static func parseKey(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
            return trimmed.uppercased()
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return parseIssueKey(fromURL: url)
    }

    static func parseIssueKey(fromURL url: URL) -> String? {
        let pathComponents = url.path.split(separator: "/").map(String.init)

        // …/browse/ENG-123
        if let index = pathComponents.firstIndex(of: "browse"), index + 1 < pathComponents.count {
            let candidate = pathComponents[index + 1]
            if candidate.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
                return candidate.uppercased()
            }
        }

        // …/issues/ENG-123 (cloud software board deep links)
        if let index = pathComponents.firstIndex(of: "issues"), index + 1 < pathComponents.count {
            let candidate = pathComponents[index + 1]
            if candidate.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
                return candidate.uppercased()
            }
        }

        // ?selectedIssue=ENG-123
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "selectedIssue" })?.value,
           value.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
            return value.uppercased()
        }

        return nil
    }
}

/// Parses GitLab merge-request URLs out of strings the retained WebView
/// already rendered. Results live only in memory.
nonisolated enum GitLabSourceContext {
    struct MergeRequestInfo: Equatable {
        let iid: String
        let projectIdentity: String
        let projectURL: URL
    }

    /// `https://host/group/project/-/merge_requests/42[...]`
    static func parseMergeRequest(from raw: String) -> MergeRequestInfo? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return parseMergeRequest(fromURL: url)
    }

    static func parseMergeRequest(fromURL url: URL) -> MergeRequestInfo? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              let iidMatch = url.path.firstMatch(of: /\/-\/merge_requests\/(\d+)/) else {
            return nil
        }
        let iid = String(iidMatch.1)
        let projectPath = String(url.path[..<iidMatch.range.lowerBound])
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        components.query = nil
        components.fragment = nil
        guard let projectURL = components.url else { return nil }
        guard let identity = projectIdentity(fromProjectHost: url.host ?? "", path: components.path) else {
            return nil
        }
        return MergeRequestInfo(iid: iid, projectIdentity: identity, projectURL: projectURL)
    }

    /// Normalized MR URL identity: lowercase host plus project path with
    /// `.git` and any `/-/merge_requests/<iid>` suffix removed.
    static func projectIdentity(fromMergeRequestURL url: URL) -> String? {
        parseMergeRequest(fromURL: url)?.projectIdentity
    }

    fileprivate static func projectIdentity(fromProjectHost host: String, path: String) -> String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else { return nil }
        return ([host.lowercased()] + segments.map { $0.lowercased() }).joined(separator: "/")
    }
}
