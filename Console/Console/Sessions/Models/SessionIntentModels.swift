import Foundation

/// Why a session exists. Drives generated local names, icons, and
/// remembered workspace choices. Source metadata never becomes a Claude prompt.
enum SessionPurpose: String, Codable, CaseIterable {
    case blank
    case newTicket
    case existingTicket
    case review
    case general

    var displayName: String {
        switch self {
        case .newTicket: return "New Ticket"
        case .existingTicket: return "Existing Ticket"
        case .review: return "Review an MR"
        case .general: return "Agent NHL"
        case .blank: return "New Terminal Session"
        }
    }

    var intentDescription: String {
        switch self {
        case .newTicket:
            return "Clean, idle Claude session for starting new ticket work."
        case .existingTicket:
            return "Opens an idle session in the ticket's workspace. Type the work context yourself — ticket details stay in Console."
        case .review:
            return "Opens an idle session in the merge-request workspace. Type the review context yourself — MR details stay in Console."
        case .general:
            return "Clean, idle Claude session for anything else."
        case .blank:
            return "Plain command-line terminal in the Session Folder. No Claude Code."
        }
    }

    var symbolName: String {
        switch self {
        case .newTicket: return "plus.square.dashed"
        case .existingTicket: return "ticket"
        case .review: return "eye"
        case .general: return "terminal"
        case .blank: return "apple.terminal"
        }
    }

    /// Automatic session-name base when the user supplies no override.
    func defaultName(source: SessionLaunchSource?) -> String {
        switch self {
        case .newTicket: return "New Ticket"
        case .general: return "General"
        case .blank: return "Blank"
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
/// `name` is the local Console display name and is never passed to Claude.
struct SessionCreationRequest: Equatable {
    let purpose: SessionPurpose
    let name: String
    let workingDirectory: URL
    let source: SessionLaunchSource?
    /// Explicit Claude Code agent; nil falls back to the purpose's default.
    let agent: String?
    /// Tool access the Claude process is launched with.
    let toolProfile: SessionToolProfile
    /// False for background launches: the new session is not selected, does
    /// not claim keyboard focus, and does not retire the Restore Sessions offer.
    let revealsSession: Bool

    init(
        purpose: SessionPurpose,
        name: String,
        workingDirectory: URL,
        source: SessionLaunchSource? = nil,
        agent: String? = nil,
        toolProfile: SessionToolProfile = .standard,
        revealsSession: Bool = true
    ) {
        self.purpose = purpose
        self.name = name
        self.workingDirectory = workingDirectory
        self.source = source
        self.agent = agent
        self.toolProfile = toolProfile
        self.revealsSession = revealsSession
    }
}

/// Tool access for one Claude launch. Applies to that process only; a later
/// resume of the same conversation launches with `.standard`.
enum SessionToolProfile: Equatable {
    /// Bypassed permission prompts and every tool, as the user configured.
    case standard
    /// Unattended preparation that cannot change anything: only Read, Grep and
    /// Glob exist (no Bash, edits, web or MCP tools), nothing bypasses
    /// permissions, and anything that would prompt is denied. The
    /// `contextDirectory` is readable through `--add-dir`.
    case readOnlyPrep(contextDirectory: URL)
}

/// A user-configured local folder sessions can open in.
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

// MARK: - New-ticket display names

/// Display-name rules for new-ticket session creation. The story number is
/// the identity the developer recognizes: `NMA-1234` renders as `NMA-1234`.
/// Any other project key keeps its full key. Local display only — the name
/// never reaches Claude.
nonisolated enum NewTicketSessionNaming {
    /// `NMA-1234` → `NMA-1234`; any other key keeps its full uppercased key.
    static func displayName(forJiraKey key: String) -> String {
        key.uppercased()
    }

    /// Parses user-typed story input — `1234`, `S-1234`, `NMA-1234`, or
    /// `NMA1234` — into the bare digits. Anything else is rejected.
    static func storyNumber(fromRaw raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [/^(\d+)$/, /^(?i)S-?(\d+)$/, /^(?i)NMA-?(\d+)$/] {
            if let match = trimmed.firstMatch(of: pattern) {
                return String(match.1)
            }
        }
        return nil
    }

    /// Display name for a parsed story number: always the `NMA-` form, since
    /// the picker's New Ticket step asks for NMA story numbers.
    static func displayName(forStoryNumber number: String) -> String {
        displayName(forJiraKey: "NMA-\(number)")
    }

    /// Resolves a legacy Console new-ticket display name `S-1234` back to its
    /// full Jira key `NMA-1234`. Current names are already full keys and need
    /// no translation; anything unrecognized returns nil so callers can fall
    /// through to generic key parsing.
    static func jiraKey(forDisplayName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: /^(?i)S-(\d+)$/) else { return nil }
        return "NMA-\(match.1)"
    }
}

// MARK: - Source context parsing (memory-only)

/// Parses Jira keys and URLs out of strings the retained WebView already
/// rendered. Results live only in memory.
nonisolated enum JiraSourceContext {
    /// Console names new-ticket sessions with the real story key `NMA-<n>`.
    /// Legacy `S-<n>` names still resolve to the same key, so any key parsed
    /// out of a Console label, session name, or title points at `NMA-<n>`.
    static func normalizedConsoleKey(_ key: String) -> String {
        NewTicketSessionNaming.jiraKey(forDisplayName: key) ?? key
    }

    /// Only resolve an unambiguous issue key; never guess among multiple stories.
    static func issueKey(in text: String) -> String? {
        let keys = Set(text.matches(of: /\b[A-Z][A-Z0-9]*-\d+\b/).map { String($0.output) })
        guard keys.count == 1, let key = keys.first else { return nil }
        return normalizedConsoleKey(key)
    }

    static func issueURL(key: String, configuredURL: String) -> URL? {
        guard let key = parseKey(from: key),
              var components = URLComponents(string: configuredURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        // Preserve a self-hosted Jira context path, e.g. /jira/browse/ENG-123.
        let parts = components.path.split(separator: "/").map(String.init)
        let routes = ["browse", "issues", "plugins", "secure", "projects"]
        let cloudRoute = parts.indices.first { index in
            parts[index] == "jira" && index + 1 < parts.count
                && ["software", "core", "servicedesk"].contains(parts[index + 1])
        }
        let routeIndex = cloudRoute ?? parts.firstIndex { routes.contains($0) }
        let prefix = routeIndex.map { Array(parts.prefix($0)) } ?? parts
        components.path = "/" + (prefix + ["browse", key]).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Uppercase project prefix of a key like `ENG-123` → `ENG`.
    static func projectKeyPrefix(of key: String) -> String? {
        guard let match = normalizedConsoleKey(key).firstMatch(of: /^([A-Za-z][A-Za-z0-9]*)-\d+$/) else { return nil }
        return String(match.1).uppercased()
    }

    /// Accepts a bare issue key (`ENG-123`) or a Jira issue URL
    /// (`…/browse/ENG-123`, `…/issues/ENG-123`, `?selectedIssue=ENG-123`).
    static func parseKey(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
            return normalizedConsoleKey(trimmed.uppercased())
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
                return normalizedConsoleKey(candidate.uppercased())
            }
        }

        // …/issues/ENG-123 (cloud software board deep links)
        if let index = pathComponents.firstIndex(of: "issues"), index + 1 < pathComponents.count {
            let candidate = pathComponents[index + 1]
            if candidate.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
                return normalizedConsoleKey(candidate.uppercased())
            }
        }

        // ?selectedIssue=ENG-123
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "selectedIssue" })?.value,
           value.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
            return normalizedConsoleKey(value.uppercased())
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
