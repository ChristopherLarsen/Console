import Foundation

/// Abstraction over yesterday-activity collection so tests inject synthetic
/// data instead of running git.
protocol BriefActivityCollecting: Sendable {
    func collectActivities(_ request: BriefCollectionRequest) async -> BriefCollectionResult
}

/// Collects attributed commit subjects across registered session workspaces.
/// Local-only: reads each repository's own history through the system git
/// binary; never touches JIRA/GitLab web content or the network.
struct BriefActivityCollector: BriefActivityCollecting, BriefIdentityReading {
    private let processRunner: ProcessRunning
    private let gitExecutablePath: String

    init(processRunner: ProcessRunning = SystemProcessRunner(),
         gitExecutablePath: String = "/usr/bin/git") {
        self.processRunner = processRunner
        self.gitExecutablePath = gitExecutablePath
    }

    /// Commit activities across `request.sources` whose author date falls
    /// inside the half-open range, filtered to each source's selected
    /// identity. Unreadable paths and non-repositories are skipped silently.
    func collectActivities(_ request: BriefCollectionRequest) async -> BriefCollectionResult {
        var activities: [CommitActivity] = []
        var repositories: [BriefSourceRepository] = []
        var seenIdentities = Set<String>()

        for source in request.sources {
            let canonical = await canonicalRepositoryIdentity(at: source.path)
                ?? source.path
            if seenIdentities.insert(canonical).inserted {
                repositories.append(
                    BriefSourceRepository(displayName: source.displayName, identity: canonical)
                )
            }

            guard source.identity.isUsable else { continue }

            let isoStart = iso8601String(from: request.rangeStart, calendar: request.calendar)
            // `git log --since/--until` bounds by committer date, so an
            // amended/rebased commit authored in range but committed after it
            // would be dropped. `--since` alone is a safe superset for an
            // author-date range (committer date is never earlier than author
            // date); the author-date window is enforced below via `occurring`.
            let result = try? await processRunner.run(
                executablePath: gitExecutablePath,
                arguments: [
                    "-C", source.path, "log", "--no-merges",
                    "--since=\(isoStart)",
                    "--pretty=format:\(BriefComposer.gitLogFormat)"
                ],
                workingDirectory: nil
            )
            guard let result, result.succeeded else { continue }

            let parsed = BriefComposer.parseGitLogOutput(
                result.standardOutput,
                repositoryName: source.displayName,
                repositoryIdentity: canonical
            )
            let attributed = BriefComposer.matching(source.identity, in: parsed)
            let inRange = BriefComposer.occurring(attributed, in: request.interval)
            activities.append(contentsOf: inRange)
        }

        return BriefCollectionResult(
            activities: BriefComposer.deduplicated(activities),
            sourceRepositories: repositories
        )
    }

    func readConfiguredIdentity(at path: String) async -> BriefAuthorIdentity {
        let name = await gitConfigValue("user.name", at: path)
        let email = await gitConfigValue("user.email", at: path)
        // `git log %aE/%aN` report mailmap-canonical identity; canonicalize the
        // raw config values the same way so defaults match collected commits.
        let canonical = await canonicalizedIdentity(name: name, email: email, at: path)
        return BriefAuthorIdentity(name: canonical.name, emails: canonical.email.isEmpty ? [] : [canonical.email])
    }

    /// Applies the repository's `.mailmap` to the configured identity, exactly
    /// as git does for `%aE`/`%aN`. Falls back to the raw values when the
    /// command is unavailable or the inputs are empty.
    private func canonicalizedIdentity(
        name: String,
        email: String,
        at path: String
    ) async -> (name: String, email: String) {
        guard !name.isEmpty || !email.isEmpty else { return (name, email) }
        let ident = "\(name) <\(email)>"
        let output = await gitOutput(
            arguments: ["-C", path, "check-mailmap", ident],
            allowedExitCodes: [0]
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") else {
            return (name, email)
        }
        let canonicalName = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let canonicalEmail = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        return (
            canonicalName.isEmpty ? name : canonicalName,
            canonicalEmail.isEmpty ? email : canonicalEmail
        )
    }

    /// Absolute Git common directory, shared by linked worktrees of one repo.
    func canonicalRepositoryIdentity(at path: String) async -> String? {
        let absolute = await gitOutput(
            arguments: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            allowedExitCodes: [0]
        )
        let trimmed = absolute.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return resolvedPath(trimmed, relativeTo: path)
        }
        let relative = await gitOutput(
            arguments: ["-C", path, "rev-parse", "--git-common-dir"],
            allowedExitCodes: [0]
        )
        let fallback = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { return nil }
        return resolvedPath(fallback, relativeTo: path)
    }

    private func resolvedPath(_ raw: String, relativeTo workspacePath: String) -> String {
        let url: URL
        if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else {
            url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true))
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func gitConfigValue(_ key: String, at path: String) async -> String {
        let output = await gitOutput(
            arguments: ["-C", path, "config", "--get", key],
            allowedExitCodes: [0, 1]
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitOutput(arguments: [String], allowedExitCodes: Set<Int32>) async -> String {
        let result = try? await processRunner.run(
            executablePath: gitExecutablePath,
            arguments: arguments,
            workingDirectory: nil
        )
        guard let result, allowedExitCodes.contains(result.exitCode) else { return "" }
        return result.standardOutput
    }

    private func iso8601String(from date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
}
