import Darwin
import Foundation

// MARK: - Transport types

/// A fully-resolved headless run request. The prompt travels via stdin, never
/// in process arguments or environment.
struct ClaudeHeadlessRequest: Equatable, Sendable {
    let executablePath: String
    let workingDirectory: String
    let arguments: [String]
    let environment: [String: String]
    let standardInputText: String
    let deadline: Date
}

/// Classifies how a headless run ended. `dispatched` distinguishes failures
/// that occurred before the process started (safe to retry) from failures
/// after dispatch (the run may have acted; writes must reconcile).
struct ClaudeHeadlessOutcome: Equatable, Sendable {
    let dispatched: Bool
    let stdout: String?
    let stderr: String?
    let failure: ClaudeHeadlessFailure?

    static func success(stdout: String?, stderr: String?) -> ClaudeHeadlessOutcome {
        ClaudeHeadlessOutcome(dispatched: true, stdout: stdout, stderr: stderr, failure: nil)
    }
}

enum ClaudeHeadlessFailure: Equatable, Sendable {
    /// The process never started; no run occurred.
    case launchFailed(reason: String)
    /// The deadline elapsed while the run was active; terminated.
    case timedOut
    /// The waiting task was cancelled; the run was terminated.
    case cancelled
    case nonZeroExit(code: Int32, message: String)
    /// Auth-style rejection. No tool ran; nothing was mutated.
    case authenticationRequired(reason: String)
}

protocol ClaudeHeadlessTransporting: Sendable {
    func run(_ request: ClaudeHeadlessRequest) async -> ClaudeHeadlessOutcome
    /// Terminates every process this transport started and has not reaped.
    /// Called on app quit so Console-owned children never outlive the app.
    func terminateAll()
}

extension ClaudeHeadlessTransporting {
    func terminateAll() {}
}

// MARK: - Flag catalog

/// Parses `claude --help` output to learn which flags the installed CLI
/// actually supports. The service never invents flags: options whose flags
/// are absent from the installed CLI are dropped (or the operation fails when
/// the flag is mandatory).
enum ClaudeFlagCatalog {
    /// Flags this feature relies on, with whether their absence is fatal.
    struct Requirement: Equatable, Sendable {
        let flag: String
        let mandatory: Bool
    }

    static let requiredFlags: [Requirement] = [
        Requirement(flag: "--print", mandatory: true),
        Requirement(flag: "--output-format", mandatory: true),
    ]

    static let optionalFlags: Set<String> = [
        "--session-id",
        "--resume",
        "--no-session-persistence",
        "--max-turns",
        "--tools",
        "--permission-prompts",
        "--json-schema",
        "--model",
        "--mcp-config",
        "--strict-mcp-config",
        "--setting-sources",
    ]

    /// Extracts `--flag` tokens from help text.
    static func supportedFlags(fromHelp helpText: String) -> Set<String> {
        var flags = Set<String>()
        for token in helpText.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            var candidate = String(token)
            if candidate.hasPrefix("-") && !candidate.hasPrefix("--") { continue }
            // Trim trailing option-value decorations like <format> or [value].
            if let angle = candidate.firstIndex(where: { $0 == "<" || $0 == "[" || $0 == "=" }) {
                candidate = String(candidate[..<angle])
            }
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ",:"))
            if candidate.hasPrefix("--"), candidate.count > 2 {
                flags.insert(candidate)
            }
        }
        return flags
    }

    /// Flags from `requiredFlags` missing from the installed CLI.
    static func missingRequiredFlags(in supported: Set<String>) -> [String] {
        requiredFlags.map(\.flag).filter { !supported.contains($0) }
    }

    /// Splits `optionalFlags` into supported and unsupported for the check
    /// surfaced in Settings ("installed CLI flags validated, never invented").
    static func unsupportedOptionalFlags(in supported: Set<String>) -> [String] {
        optionalFlags.subtracting(supported).sorted()
    }
}

// MARK: - Invocation builder

/// Builds the argv for a headless run. Every flag is validated against the
/// flag catalog of the installed CLI; unsupported optional flags are omitted,
/// unsupported mandatory capabilities raise.
enum HeadlessInvocationBuilder {
    struct Options: Equatable, Sendable {
        var model: String?
        var maxTurns: Int
        var allowedTools: [String]
        var sessionID: UUID
        var resume: Bool
        var ephemeral: Bool
        var expectedSchemaJSON: String?
        var mcpConfigPath: String?
    }

    struct BuildResult: Equatable, Sendable {
        var arguments: [String]
        /// Optional flags the installed CLI does not support and that were
        /// therefore omitted.
        var droppedFlags: [String]
    }

    static func arguments(
        options: Options,
        supportedFlags: Set<String>?
    ) -> BuildResult {
        var arguments = ["-p", "--output-format", "json"]
        var dropped: [String] = []

        func include(_ flag: String, _ values: String...) {
            if let supportedFlags, !supportedFlags.contains(flag) {
                dropped.append(flag)
                return
            }
            arguments.append(flag)
            arguments.append(contentsOf: values)
        }

        if options.maxTurns > 0 {
            include("--max-turns", String(options.maxTurns))
        }
        // Empty allowedTools disables all built-in tools via "--tools \"\"".
        include("--tools", options.allowedTools.joined(separator: ","))
        // Never leave headless runs waiting on a permission prompt.
        include("--permission-prompts", "none")
        if options.resume {
            include("--resume", options.sessionID.uuidString)
        } else {
            include("--session-id", options.sessionID.uuidString)
        }
        if options.ephemeral {
            include("--no-session-persistence")
        }
        if let model = options.model, !model.isEmpty {
            include("--model", model)
        }
        if let schema = options.expectedSchemaJSON, !schema.isEmpty {
            include("--json-schema", schema)
        }
        if let mcpConfigPath = options.mcpConfigPath, !mcpConfigPath.isEmpty {
            include("--mcp-config", mcpConfigPath)
            include("--strict-mcp-config")
        } else {
            // No MCP server is configured for managed runs, so pin the tool
            // surface to nothing: an empty server config with
            // --strict-mcp-config ignores any user-level MCP configuration.
            include("--mcp-config", "{\"mcpServers\":{}}")
            include("--strict-mcp-config")
        }
        return BuildResult(arguments: arguments, droppedFlags: dropped.sorted())
    }
}

// MARK: - Real process transport

/// Runs `claude -p` as a direct child process (never through a shell) with
/// the prompt on stdin, enforcing the request deadline by terminating the
/// child. Owns nothing beyond the single run; app-quit cleanup only ever
/// concerns runs this service started.
final class HeadlessProcessTransport: ClaudeHeadlessTransporting, @unchecked Sendable {
    static let terminationGrace: TimeInterval = 2

    private let lock = NSLock()
    private var liveProcesses: [Process] = []

    func terminateAll() {
        lock.lock()
        let processes = liveProcesses
        lock.unlock()
        for process in processes {
            Self.terminate(process)
        }
    }

    func run(_ request: ClaudeHeadlessRequest) async -> ClaudeHeadlessOutcome {
        if Task.isCancelled {
            return ClaudeHeadlessOutcome(dispatched: false, stdout: nil, stderr: nil, failure: .cancelled)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            return ClaudeHeadlessOutcome(
                dispatched: false,
                stdout: nil,
                stderr: nil,
                failure: .launchFailed(reason: String(describing: error))
            )
        }
        lock.lock()
        liveProcesses.append(process)
        lock.unlock()
        defer {
            lock.lock()
            liveProcesses.removeAll { $0 === process }
            lock.unlock()
        }

        // Prompt goes to stdin; the pipe is closed immediately so the CLI
        // sees EOF.
        let stdinHandle = stdinPipe.fileHandleForWriting
        let inputText = request.standardInputText
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = inputText.data(using: .utf8) {
                try? stdinHandle.write(contentsOf: data)
            }
            try? stdinHandle.close()
        }

        async let stdoutData = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.readToEnd(stderrPipe.fileHandleForReading)

        let exit = await Self.awaitExit(process, deadline: request.deadline)

        if Task.isCancelled {
            Self.terminate(process)
            _ = await stdoutData
            _ = await stderrData
            return ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .cancelled)
        }

        switch exit {
        case .timedOut:
            _ = await stdoutData
            _ = await stderrData
            return ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .timedOut)
        case .exited(let code):
            let stdout = String(data: await stdoutData, encoding: .utf8)
            let stderr = String(data: await stderrData, encoding: .utf8)
            if code == 0 {
                return .success(stdout: stdout, stderr: stderr)
            }
            let message = Self.sanitizedMessage(stdout: stdout, stderr: stderr)
            if Self.looksLikeAuthenticationFailure(message) {
                return ClaudeHeadlessOutcome(dispatched: true, stdout: stdout, stderr: stderr, failure: .authenticationRequired(reason: message))
            }
            return ClaudeHeadlessOutcome(
                dispatched: true,
                stdout: stdout,
                stderr: stderr,
                failure: .nonZeroExit(code: code, message: message)
            )
        }
    }

    // MARK: Helpers

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private enum ProcessExit {
        case exited(Int32)
        case timedOut
    }

    /// Waits for process exit, racing the deadline. On deadline the child is
    /// terminated (SIGTERM, then SIGKILL after a short grace).
    private static func awaitExit(_ process: Process, deadline: Date) async -> ProcessExit {
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate()
            process.terminationHandler = { terminated in
                if gate.claim() {
                    continuation.resume(returning: .exited(terminated.terminationStatus))
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let interval = deadline.timeIntervalSinceNow
                if interval > 0 {
                    Thread.sleep(forTimeInterval: min(interval, 3600))
                }
                guard process.isRunning else { return } // termination handler owns the resume
                if gate.claim() {
                    Self.terminate(process)
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let hardDeadline = Date().addingTimeInterval(terminationGrace)
        while process.isRunning && Date() < hardDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Failure text classification. Messages are CLI diagnostics, never
    /// ticket content.
    static func looksLikeAuthenticationFailure(_ message: String) -> Bool {
        let markers = ["api key", "login", "authentication", "unauthorized", "oauth", "subscription"]
        let lowered = message.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    /// Bounded failure text: no prompts, no results, only the CLI's own
    /// diagnostic tail.
    static func sanitizedMessage(stdout: String?, stderr: String?) -> String {
        let source = [stderr, stdout].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? ""
        let lines = source
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " | ")
        return String(tail.prefix(400))
    }
}

/// Ensures exactly one of two racing continuations resumes.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true exactly once, for whichever racer claims it first.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
