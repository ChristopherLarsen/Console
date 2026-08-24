import Foundation

/// Host-neutral merge-request URL parsing. Detects a GitLab merge request
/// (`/-/merge_requests/<iid>`) by shape, and exposes one identity scheme so
/// workspace associations resolve consistently.
nonisolated enum MergeRequestSourceContext {
    struct ParsedMergeRequest: Equatable {
        let iid: String
        let projectIdentity: String
        let projectURL: URL
    }

    static func parse(from raw: String) -> ParsedMergeRequest? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return parse(fromURL: url)
    }

    static func parse(fromURL url: URL) -> ParsedMergeRequest? {
        guard let gitlab = GitLabSourceContext.parseMergeRequest(fromURL: url) else { return nil }
        return ParsedMergeRequest(
            iid: gitlab.iid,
            projectIdentity: gitlab.projectIdentity,
            projectURL: gitlab.projectURL
        )
    }

    /// Normalized project identity (`host/project/path`) for any supported
    /// merge-request URL.
    static func projectIdentity(inURL url: URL) -> String? {
        parse(fromURL: url)?.projectIdentity
    }

    /// Builds a launch source from the URL a retained WebView is currently
    /// showing, or nil when that page does not display a merge request.
    static func launchSource(forURL url: URL, pageTitle: String?) -> SessionLaunchSource? {
        guard let parsed = parse(fromURL: url) else { return nil }
        return .mergeRequest(iid: parsed.iid, title: pageTitle, url: url)
    }

    /// Normalizes HTTPS (`https://host/path.git`) and SSH
    /// (`git@host:path.git`, `ssh://git@host/path.git`) remote URLs to
    /// lowercase host plus project path without `.git`. Merge-request tails
    /// collapse onto the project identity so remotes and list URLs match one
    /// another.
    static func normalizeRemoteURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host: String
        var path: String

        if let scpLike = trimmed.firstMatch(of: /^(?:[^@\/]+@)([^:\/]+):(\/?.+)$/) {
            host = String(scpLike.1)
            path = String(scpLike.2)
        } else if let url = URL(string: trimmed), let urlHost = url.host, url.scheme != nil {
            host = urlHost
            path = url.path
        } else {
            return nil
        }

        host = host.lowercased()

        // MR URLs and remotes must collapse to one identity: drop any
        // request tail before trimming `.git`.
        if let mrTail = path.range(of: "/-/merge_requests/[0-9]+", options: .regularExpression) {
            path = String(path[path.startIndex..<mrTail.lowerBound])
        }

        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return nil }
        if segments.last?.hasSuffix(".git") == true {
            segments[segments.count - 1] = String(segments.last!.dropLast(4))
            if segments.last?.isEmpty == true { segments.removeLast() }
        }
        guard !segments.isEmpty else { return nil }

        return ([host] + segments.map { $0.lowercased() }).joined(separator: "/")
    }
}
