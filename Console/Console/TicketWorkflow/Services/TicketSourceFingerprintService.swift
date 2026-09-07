import CryptoKit
import Foundation

/// Computes a bounded git source fingerprint for Ticket Work evidence checks.
///
/// Probes HEAD, staged, unstaged, and non-ignored untracked changes through
/// injected ``ProcessRunning``. Any probe failure, non-zero exit, or truncated
/// output yields ``TicketSourceFingerprint/incomplete(at:)``. Never accepts
/// ticket keys or Jira fields — only a checkout path.
nonisolated struct TicketSourceFingerprintService: Sendable {
    nonisolated static let defaultGitExecutablePath = "/usr/bin/git"
    nonisolated static let defaultLookupTimeout: Duration = .seconds(5)
    nonisolated static let defaultMaxOutputBytes = 65_536

    private let processRunner: any ProcessRunning
    private let gitExecutablePath: String
    private let lookupTimeout: Duration
    private let now: @Sendable () -> Date

    init(
        processRunner: any ProcessRunning = SystemProcessRunner(
            maxOutputBytesPerStream: TicketSourceFingerprintService.defaultMaxOutputBytes
        ),
        gitExecutablePath: String = TicketSourceFingerprintService.defaultGitExecutablePath,
        lookupTimeout: Duration = TicketSourceFingerprintService.defaultLookupTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processRunner = processRunner
        self.gitExecutablePath = gitExecutablePath
        self.lookupTimeout = lookupTimeout
        self.now = now
    }

    /// Capture a fingerprint for `checkoutPath`. Incomplete when the path is
    /// empty, inaccessible, not a git repo, or any probe fails.
    func fingerprint(checkoutPath: String) async -> TicketSourceFingerprint {
        let capturedAt = now()
        let path = checkoutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .incomplete(at: capturedAt)
        }
        // Local path checks only — avoid MainActor SessionWorkspaceStore.
        guard Self.isAccessibleDirectory(atPath: path),
              Self.isGitRepository(atPath: path) else {
            return .incomplete(at: capturedAt)
        }

        do {
            let headOID = try await runProbe(
                checkoutPath: path,
                arguments: ["rev-parse", "HEAD"],
                digestOutput: false
            )
            let stagedDigest = try await runProbe(
                checkoutPath: path,
                arguments: ["diff-index", "--cached", "-z", "HEAD"],
                digestOutput: true
            )
            let unstagedDigest = try await runProbe(
                checkoutPath: path,
                arguments: ["diff-files", "-z"],
                digestOutput: true
            )
            let untrackedDigest = try await runProbe(
                checkoutPath: path,
                arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
                digestOutput: true
            )
            return TicketSourceFingerprint(
                headOID: headOID,
                stagedDigest: stagedDigest,
                unstagedDigest: unstagedDigest,
                untrackedDigest: untrackedDigest,
                isComplete: true,
                capturedAt: capturedAt
            )
        } catch {
            return .incomplete(at: capturedAt)
        }
    }

    // MARK: - Probes

    private enum ProbeError: Error {
        case failed
        case truncated
        case emptyHead
    }

    /// Runs one git probe under `-C checkoutPath`. When `digestOutput` is true,
    /// returns a SHA-256 hex digest of stdout; otherwise returns trimmed stdout.
    private func runProbe(
        checkoutPath: String,
        arguments: [String],
        digestOutput: Bool
    ) async throws -> String {
        let argv = ["-C", checkoutPath, "--no-optional-locks"] + arguments
        let result: ProcessResult
        do {
            result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
                let runner = processRunner
                let executable = gitExecutablePath
                let timeout = lookupTimeout
                group.addTask {
                    try await runner.run(
                        executablePath: executable,
                        arguments: argv,
                        workingDirectory: checkoutPath,
                        deadline: nil
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProbeError.failed
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else {
                    throw ProbeError.failed
                }
                return value
            }
        } catch {
            throw ProbeError.failed
        }

        guard result.exitCode == 0 else {
            throw ProbeError.failed
        }
        if result.standardOutputTruncated || result.standardErrorTruncated {
            throw ProbeError.truncated
        }

        if digestOutput {
            return Self.digest(result.standardOutput)
        }
        let head = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else {
            throw ProbeError.emptyHead
        }
        return head
    }

    nonisolated static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func isAccessibleDirectory(atPath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: path)
    }

    nonisolated private static func isGitRepository(atPath path: String) -> Bool {
        let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit.path)
    }
}
