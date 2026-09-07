import Foundation

/// Matches a code-host project identity against the local remotes of saved
/// workspaces. Lookup is a bounded `git config` read: no network, and only
/// normalized identities are retained. Linked worktrees, includes, and
/// relative `gitdir` pointers are resolved by Git itself.
@MainActor
final class RepositoryIdentityResolver {
    nonisolated static let defaultGitExecutablePath = "/usr/bin/git"
    nonisolated static let defaultLookupTimeout: Duration = .seconds(5)
    nonisolated static let defaultMaxOutputBytes = 32_768

    private let processRunner: any ProcessRunning
    private let gitExecutablePath: String
    private let lookupTimeout: Duration

    init(
        processRunner: any ProcessRunning = SystemProcessRunner(
            maxOutputBytesPerStream: RepositoryIdentityResolver.defaultMaxOutputBytes
        ),
        gitExecutablePath: String = RepositoryIdentityResolver.defaultGitExecutablePath,
        lookupTimeout: Duration = RepositoryIdentityResolver.defaultLookupTimeout
    ) {
        self.processRunner = processRunner
        self.gitExecutablePath = gitExecutablePath
        self.lookupTimeout = lookupTimeout
    }

    // MARK: - Remote discovery

    /// Normalized remote identities for the repository at `directory`.
    /// Returns an empty set when the folder is not a readable Git repository,
    /// Git is missing, or lookup fails.
    func remoteIdentities(forDirectoryAt directory: URL) async -> Set<String> {
        guard SessionWorkspaceStore.isGitRepository(atPath: directory.path) else {
            return []
        }
        return Set(
            await readRemoteURLs(directory: directory)
                .compactMap(MergeRequestSourceContext.normalizeRemoteURL)
        )
    }

    /// Parses `git config --null --get-regexp` records (`key\nvalue\0`).
    /// Only `remote.<name>.url` keys are kept; other `url` values are ignored.
    nonisolated static func remoteURLs(fromNullDelimitedConfigOutput output: String) -> [String] {
        var urls: [String] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("remote."),
                  key.hasSuffix(".url"),
                  key != "remote.url",
                  !value.isEmpty else {
                continue
            }
            urls.append(String(value))
        }
        return urls
    }

    private func readRemoteURLs(directory: URL) async -> [String] {
        let path = directory.standardizedFileURL.path
        guard !path.isEmpty else { return [] }

        let runner = processRunner
        let executable = gitExecutablePath
        let arguments = [
            "-C", path,
            "config",
            "--local",
            "--includes",
            "--null",
            "--get-regexp",
            #"^remote\..*\.url$"#,
        ]
        let timeout = lookupTimeout

        do {
            let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
                group.addTask {
                    try await runner.run(
                        executablePath: executable,
                        arguments: arguments,
                        workingDirectory: path
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw GitRemoteLookupTimeout()
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else {
                    throw GitRemoteLookupTimeout()
                }
                return value
            }
            guard !result.standardOutputTruncated else { return [] }
            // 0 = matches, 1 = no matching keys. Anything else (missing repo,
            // bad gitdir, git not usable) is no match.
            guard result.exitCode == 0 || result.exitCode == 1 else { return [] }
            return Self.remoteURLs(fromNullDelimitedConfigOutput: result.standardOutput)
        } catch {
            return []
        }
    }

    // MARK: - Matching

    enum MatchOutcome: Equatable {
        case unique(SessionWorkspace)
        case ambiguous
        case none
    }

    /// Matches an MR project identity (`host/project/path`) against the
    /// remotes of each workspace. Exactly one match resolves; zero or several
    /// leave resolution to the next step in the documented order. Path
    /// aliases (symlinks) of one physical checkout count as a single match.
    func match(projectIdentity: String, in workspaces: [SessionWorkspace]) async -> MatchOutcome {
        var matches: [SessionWorkspace] = []
        var seenCanonicalPaths: Set<String> = []
        for workspace in workspaces {
            let identities = await remoteIdentities(forDirectoryAt: workspace.directoryURL)
            guard identities.contains(projectIdentity) else { continue }
            if seenCanonicalPaths.insert(CheckoutPath.canonical(workspace.directoryURL)).inserted {
                matches.append(workspace)
            }
        }
        switch matches.count {
        case 1:
            return .unique(matches[0])
        case 0:
            return .none
        default:
            return .ambiguous
        }
    }
}

private struct GitRemoteLookupTimeout: Error {}
