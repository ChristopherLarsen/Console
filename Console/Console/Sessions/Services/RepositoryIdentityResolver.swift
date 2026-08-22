import Foundation

/// Inspects local Git repositories' configured remotes (`.git/config`) to
/// match a GitLab merge request's project against saved workspaces. No
/// network access ever happens: only local config files are read.
@MainActor
final class RepositoryIdentityResolver {
    typealias ConfigReader = (URL) -> String?

    private let configReader: ConfigReader

    init(configReader: @escaping ConfigReader = { directory in
        RepositoryIdentityResolver.readGitConfig(directory: directory)
    }) {
        self.configReader = configReader
    }

    // MARK: - Remote discovery

    /// Normalized remote identities for the repository at `directory`.
    /// Returns an empty set when the folder is not a readable Git repository.
    func remoteIdentities(forDirectoryAt directory: URL) -> Set<String> {
        guard SessionWorkspaceStore.isGitRepository(atPath: directory.path),
              let contents = configReader(directory) else {
            return []
        }
        return Set(
            Self.remoteURLs(inConfig: contents)
                .compactMap(GitLabSourceContext.normalizeRemoteURL)
        )
    }

    /// Parses `url = …` values from `[remote "…"]` sections of a git config.
    static func remoteURLs(inConfig config: String) -> [String] {
        var urls: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("url"),
                  let equals = trimmed.firstIndex(of: "=") else {
                continue
            }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                urls.append(value)
            }
        }
        return urls
    }

    private nonisolated static func readGitConfig(directory: URL) -> String? {
        let dotGit = directory.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try? String(contentsOf: dotGit.appendingPathComponent("config"), encoding: .utf8)
        }

        // Worktrees/submodules: `.git` is a file pointing at the real gitdir.
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
              pointer.hasPrefix("gitdir:") else {
            return nil
        }
        var gitdir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if gitdir.hasPrefix("~") {
            gitdir = NSString(string: gitdir).expandingTildeInPath
        }
        if !gitdir.hasPrefix("/") {
            gitdir = directory.appendingPathComponent(gitdir).path
        }
        return try? String(contentsOf: URL(fileURLWithPath: gitdir, isDirectory: true).appendingPathComponent("config"), encoding: .utf8)
    }

    // MARK: - Matching

    enum MatchOutcome: Equatable {
        case unique(SessionWorkspace)
        case ambiguous
        case none
    }

    /// Matches an MR project identity (`host/project/path`) against the
    /// remotes of each workspace. Exactly one match resolves; zero or several
    /// leave resolution to the next step in the documented order.
    func match(projectIdentity: String, in workspaces: [SessionWorkspace]) -> MatchOutcome {
        let matches = workspaces.filter { workspace in
            remoteIdentities(forDirectoryAt: workspace.directoryURL).contains(projectIdentity)
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
