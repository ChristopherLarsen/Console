import Foundation

/// Read-only lookup of local branch and dirty state. Never mutates the
/// working copy: no reset, stash, checkout, or worktree creation.
protocol LocalGitInspecting: Sendable {
    func inspect(canonicalPath: String) async -> LocalGitWorkingCopyState
}

/// Bounded `git status --porcelain --branch` read. Linked worktrees report
/// their own branch/dirty state because Git is invoked with `-C` on that
/// checkout, matching item 11's worktree-aware config lookup.
struct LocalGitWorkingCopyInspector: LocalGitInspecting {
    nonisolated static let defaultGitExecutablePath = "/usr/bin/git"
    nonisolated static let defaultLookupTimeout: Duration = .seconds(5)
    nonisolated static let defaultMaxOutputBytes = 32_768

    private let processRunner: any ProcessRunning
    private let gitExecutablePath: String
    private let lookupTimeout: Duration

    init(
        processRunner: any ProcessRunning = SystemProcessRunner(
            maxOutputBytesPerStream: LocalGitWorkingCopyInspector.defaultMaxOutputBytes
        ),
        gitExecutablePath: String = LocalGitWorkingCopyInspector.defaultGitExecutablePath,
        lookupTimeout: Duration = LocalGitWorkingCopyInspector.defaultLookupTimeout
    ) {
        self.processRunner = processRunner
        self.gitExecutablePath = gitExecutablePath
        self.lookupTimeout = lookupTimeout
    }

    func inspect(canonicalPath: String) async -> LocalGitWorkingCopyState {
        guard !canonicalPath.isEmpty else { return .unavailable }
        guard SessionWorkspaceStore.isAccessibleDirectory(atPath: canonicalPath) else {
            return .unavailable
        }
        guard SessionWorkspaceStore.isGitRepository(atPath: canonicalPath) else {
            return .notARepository
        }

        let runner = processRunner
        let executable = gitExecutablePath
        let arguments = [
            "-C", canonicalPath,
            "--no-optional-locks",
            "status",
            "--porcelain=v1",
            "--branch",
            "--untracked-files=normal",
        ]
        let timeout = lookupTimeout

        do {
            let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
                group.addTask {
                    try await runner.run(
                        executablePath: executable,
                        arguments: arguments,
                        workingDirectory: canonicalPath
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw GitWorkingCopyLookupTimeout()
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else {
                    throw GitWorkingCopyLookupTimeout()
                }
                return value
            }
            // Conservative: truncated porcelain still means "dirty enough to warn".
            if result.exitCode != 0 {
                return result.exitCode == 128 ? .notARepository : .unavailable
            }
            var state = Self.workingCopyState(fromPorcelainStatus: result.standardOutput)
            if result.standardOutputTruncated {
                state.isDirty = true
            }
            return state
        } catch {
            return .unavailable
        }
    }

    /// Parses `git status --porcelain=v1 --branch` (`##` header plus change lines).
    nonisolated static func workingCopyState(fromPorcelainStatus output: String) -> LocalGitWorkingCopyState {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let headerLine = lines.first, headerLine.hasPrefix("## ") else {
            return .unavailable
        }
        let header = String(headerLine.dropFirst(3))
        var isDetached = false
        var branchName: String?

        if header.hasPrefix("HEAD (no branch)") {
            isDetached = true
            branchName = nil
        } else if header.hasPrefix("No commits yet on ") {
            let rest = String(header.dropFirst("No commits yet on ".count))
            branchName = rest.components(separatedBy: "...").first?
                .split(separator: " ").first
                .map(String.init)
        } else {
            branchName = header.components(separatedBy: "...").first?
                .split(separator: " ").first
                .map(String.init)
        }

        let dirty = lines.dropFirst().contains { !$0.hasPrefix("##") }
        return LocalGitWorkingCopyState(
            isRepository: true,
            isAvailable: true,
            branchName: branchName,
            isDetached: isDetached,
            isDirty: dirty
        )
    }
}

private struct GitWorkingCopyLookupTimeout: Error {}
