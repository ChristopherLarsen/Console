import Foundation
import SwiftUI

/// Headless envelope emitted by `claude -p --output-format json`.
struct ClaudeHeadlessEnvelope: Decodable, Equatable, Sendable {
    let type: String?
    let subtype: String?
    let isError: Bool?
    let result: String?
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case isError = "is_error"
        case result
        case sessionID = "session_id"
    }
}

enum ClaudeHeadlessEnvelopeDecoder {
    static func decode(_ stdout: String?) -> ClaudeHeadlessEnvelope? {
        guard let payload = JiraStructuredResultDecoder.jsonPayload(from: stdout) else { return nil }
        return try? JSONDecoder().decode(ClaudeHeadlessEnvelope.self, from: Data(payload.utf8))
    }
}

/// Console-managed headless Claude access.
///
/// Separate owner from the user Sessions feature: dedicated working
/// directory, dedicated owned session IDs, no row in Sessions, no terminal
/// UI. Operations run the headless CLI per request (v1) on a serial queue,
/// with deadlines, cancellation, and explicit lifecycle states surfaced to
/// Settings. Prompts and results are never logged or persisted by this
/// service; prompts travel via stdin and never appear in process arguments.
///
/// Resume identity: only session IDs this service explicitly created
/// (`--session-id`) are ever resumed (`--resume`). `--continue` is never used.
/// `--bare` is deliberately never used: it bypasses subscription OAuth.
@MainActor
@Observable
final class ManagedClaudeService {
    private(set) var state: ManagedClaudeServiceState = .stopped
    private(set) var executablePath: String?
    /// Flags the installed CLI advertised in `--help`; nil until validated.
    private(set) var supportedFlags: Set<String>?
    private(set) var lastTestDescription: String?

    var configuration: ManagedClaudeConfiguration {
        didSet {
            configuration.store()
            preparedExecutablePath = nil
        }
    }

    private let transport: ClaudeHeadlessTransporting
    private let locator: ClaudeExecutableLocator
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let gate = ClaudeSerialGate()
    private var registry: ClaudeOwnedSessionRegistry
    private var loginShellEnvironment: [String: String]?
    private var preparedExecutablePath: String?
    private var isShuttingDown = false

    init(
        transport: ClaudeHeadlessTransporting = HeadlessProcessTransport(),
        locator: ClaudeExecutableLocator? = nil,
        configuration: ManagedClaudeConfiguration = .load(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        // ClaudeExecutableLocator is MainActor-isolated; defaulting here keeps
        // the initializer's default arguments nonisolated.
        self.locator = locator ?? ClaudeExecutableLocator()
        self.configuration = configuration
        self.defaults = defaults
        self.fileManager = fileManager
        self.registry = ClaudeOwnedSessionStore.load()
    }

    // MARK: Preparation

    /// Locates the executable, creates the dedicated working directory, and
    /// validates the installed CLI's flags. Idempotent.
    func prepare() async -> Bool {
        guard !isShuttingDown else { return false }
        state = .starting
        guard let executable = locator.locate() else {
            state = .error("Claude Code executable not found")
            return false
        }
        let help = await Self.fetchHelpText(executablePath: executable)
        let flags = ClaudeFlagCatalog.supportedFlags(fromHelp: help ?? "")
        let missing = ClaudeFlagCatalog.missingRequiredFlags(in: flags)
        guard missing.isEmpty else {
            state = .error("Installed CLI lacks required flags: \(missing.joined(separator: ", "))")
            return false
        }
        do {
            try fileManager.createDirectory(
                atPath: configuration.workingDirectoryPath,
                withIntermediateDirectories: true
            )
        } catch {
            state = .error("Managed working directory could not be created")
            return false
        }
        if loginShellEnvironment == nil {
            loginShellEnvironment = SessionEnvironmentBuilder.captureLoginShellEnvironment()
        }
        executablePath = executable
        supportedFlags = flags
        preparedExecutablePath = executable
        if state != .needsAuthentication {
            state = .ready
        }
        return true
    }

    private static func fetchHelpText(executablePath: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = ["--help"]
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Operations

    /// Runs one headless operation on the serial queue. One process per
    /// operation in v1; no eternal process, no warm SDK runtime.
    func perform(_ invocation: ClaudeOperationInvocation) async throws -> ClaudeOperationOutput {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw ClaudeServiceError.shuttingDown }
        if preparedExecutablePath == nil || supportedFlags == nil {
            let prepared = await prepare()
            guard prepared, let executable = preparedExecutablePath else {
                throw ClaudeServiceError.executableUnavailable
            }
        }
        guard let executable = preparedExecutablePath, let flags = supportedFlags else {
            throw ClaudeServiceError.notPrepared
        }
        guard invocation.deadline > Date() else {
            throw ClaudeServiceError.timedOut(correlationID: invocation.correlationID)
        }

        await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        guard !isShuttingDown else { throw ClaudeServiceError.shuttingDown }
        guard invocation.deadline > Date() else {
            throw ClaudeServiceError.timedOut(correlationID: invocation.correlationID)
        }
        let missingFlags = invocation.requiredFlags.subtracting(flags)
        guard missingFlags.isEmpty else { throw ClaudeServiceError.unsupportedFlags(missingFlags.sorted()) }
        state = .busy
        defer {
            if state == .busy { state = .ready }
        }

        let build = HeadlessInvocationBuilder.arguments(
            options: HeadlessInvocationBuilder.Options(
                model: invocation.modelOverride ?? configuration.model,
                maxTurns: invocation.maxTurnsOverride ?? configuration.maxTurns,
                allowedTools: invocation.allowedToolsOverride ?? configuration.allowedTools,
                sessionID: invocation.sessionID,
                resume: invocation.resume,
                ephemeral: invocation.ephemeral,
                expectedSchemaJSON: invocation.expectedSchemaJSON,
                mcpConfigPath: nil,
                toolPermissionRules: invocation.toolPermissionRules
            ),
            supportedFlags: flags
        )
        if !build.droppedFlags.isEmpty {
            // Mandatory capabilities must never be silently absent.
            if build.droppedFlags.contains("--session-id") || build.droppedFlags.contains("--resume") {
                throw ClaudeServiceError.unsupportedFlags(build.droppedFlags)
            }
        }

        let environment = SessionEnvironmentBuilder.childEnvironment(
            base: ProcessInfo.processInfo.environment,
            loginShellEnvironment: loginShellEnvironment,
            bridge: [:]
        )

        let request = ClaudeHeadlessRequest(
            executablePath: executable,
            workingDirectory: configuration.workingDirectoryPath,
            arguments: build.arguments,
            environment: environment,
            standardInputText: invocation.prompt,
            deadline: invocation.deadline
        )

        let outcome = await transport.run(request)
        let output = try Self.interpret(outcome: outcome, invocation: invocation)
        // Non-ephemeral runs persist a transcript outside Console's control
        // (Claude Code writes it under ~/.claude/projects), so the owned
        // session ID is registered for bounded retention rotation.
        if !invocation.ephemeral {
            recordOwnedSession(invocation.sessionID)
        }
        return output
    }

    /// Maps a transport outcome to a typed output or service error. Pure, so
    /// it is directly unit-testable.
    nonisolated static func interpret(
        outcome: ClaudeHeadlessOutcome,
        invocation: ClaudeOperationInvocation
    ) throws -> ClaudeOperationOutput {
        if let failure = outcome.failure {
            switch failure {
            case .launchFailed(let reason):
                throw ClaudeServiceError.launchFailed(reason: reason)
            case .timedOut:
                throw ClaudeServiceError.timedOut(correlationID: invocation.correlationID)
            case .cancelled:
                throw ClaudeServiceError.cancelled
            case .authenticationRequired(let reason):
                throw ClaudeServiceError.needsAuthentication(reason: reason)
            case .nonZeroExit(let code, let message):
                throw ClaudeServiceError.executionFailed(reason: "exit \(code): \(message)")
            }
        }

        guard let envelope = ClaudeHeadlessEnvelopeDecoder.decode(outcome.stdout) else {
            throw ClaudeServiceError.malformedOutput(reason: "Headless output was not a decodable result envelope")
        }
        if envelope.isError == true || (envelope.subtype?.contains("error") == true) {
            let detail = envelope.result.flatMap { JiraStructuredResultDecoder.jsonPayload(from: $0) } ?? ""
            throw ClaudeServiceError.executionFailed(reason: String(detail.prefix(400)))
        }
        let reportedSessionID = envelope.sessionID.flatMap { UUID(uuidString: $0) }
        // --json-schema responses arrive in structured_output on current
        // Claude Code, often with an empty result string.
        var resultText = envelope.result
        if let raw = outcome.stdout?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let structured = object["structured_output"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            resultText = String(decoding: data, as: UTF8.self)
        }
        return ClaudeOperationOutput(
            correlationID: invocation.correlationID,
            resultText: resultText,
            sessionID: reportedSessionID
        )
    }

    /// Records an owned session and applies bounded transcript rotation.
    func recordOwnedSession(_ id: UUID) {
        registry.record(id)
        applyRetention()
    }

    private func applyRetention() {
        let evicted = registry.evictions(limit: configuration.maxRetainedSessions)
        guard !evicted.isEmpty else { return }
        registry.remove(evicted)
        ClaudeTranscriptRetention.prune(
            evictedSessionIDs: evicted,
            workingDirectory: configuration.workingDirectoryPath
        )
        ClaudeOwnedSessionStore.save(registry)
    }

    // MARK: Connection test

    /// Verifies the executable, flags, auth, and structured-output decoding
    /// with a minimal ephemeral ping. Performs no JIRA access whatsoever.
    func testConnection() async -> Bool {
        guard await prepare() else {
            lastTestDescription = "Preparation failed"
            return false
        }
        let correlationID = UUID()
        let schemaJSON = #"{"type":"object","properties":{"schemaVersion":{"type":"integer"},"correlationID":{"type":"string"},"operation":{"type":"string"}},"required":["schemaVersion","correlationID","operation"]}"#
        let prompt = """
        Reply with only this JSON object, nothing else:
        {"schemaVersion":1,"correlationID":"\(correlationID.uuidString)","operation":"ping"}
        """
        do {
            let output = try await perform(
                ClaudeOperationInvocation(
                    correlationID: correlationID,
                    prompt: prompt,
                    expectedSchemaJSON: schemaJSON,
                    ephemeral: true,
                    deadline: Date().addingTimeInterval(configuration.requestTimeout)
                )
            )
            let structured = try JiraStructuredResultDecoder.decode(output.resultText)
            guard structured.operation == "ping", structured.correlationID == correlationID else {
                lastTestDescription = "Ping response did not echo the correlation ID"
                return false
            }
            lastTestDescription = "Ready"
            return true
        } catch let error as ClaudeServiceError {
            switch error {
            case .needsAuthentication:
                state = .needsAuthentication
                lastTestDescription = "Claude Code authentication required"
            case .timedOut:
                state = .recovering
                lastTestDescription = "Ping timed out"
            default:
                state = .error(Self.errorDescription(for: error))
                lastTestDescription = Self.errorDescription(for: error)
            }
            return false
        } catch {
            lastTestDescription = "Ping failed"
            return false
        }
    }

    nonisolated static func errorDescription(for error: ClaudeServiceError) -> String {
        switch error {
        case .executableUnavailable:
            return "Claude Code executable not found"
        case .notPrepared:
            return "Service not prepared"
        case .unsupportedFlags(let flags):
            return "Installed CLI lacks flags: \(flags.joined(separator: ", "))"
        case .launchFailed(let reason):
            return "Launch failed: \(reason)"
        case .timedOut:
            return "Operation timed out"
        case .cancelled:
            return "Operation cancelled"
        case .needsAuthentication:
            return "Claude Code authentication required"
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .malformedOutput(let reason):
            return "Unexpected output: \(reason)"
        case .shuttingDown:
            return "Service is shutting down"
        }
    }

    // MARK: Lifecycle

    /// Re-runs preparation after a configuration change or failure.
    func restart() async {
        isShuttingDown = false
        preparedExecutablePath = nil
        supportedFlags = nil
        executablePath = nil
        state = .starting
        _ = await prepare()
    }

    /// App-quit cleanup: refuse new operations and terminate any live
    /// Console-owned child processes. Owned session records are already
    /// persisted incrementally.
    func cleanupForAppQuit() {
        isShuttingDown = true
        transport.terminateAll()
        state = .stopped
    }
}
