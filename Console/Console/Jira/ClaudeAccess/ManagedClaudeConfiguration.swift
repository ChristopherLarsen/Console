import Foundation

/// Configuration for the Console-managed headless Claude transport used by
/// JIRA operations. This service is a separate owner from the user Sessions
/// feature: it has its own working directory, its own owned session IDs, and
/// never appears as a row in Sessions.
struct ManagedClaudeConfiguration: Equatable, Codable, Sendable {
    /// Optional model alias; nil uses the CLI default.
    var model: String?
    /// Hard cap on agent turns per operation; JIRA operations are short.
    var maxTurns: Int
    /// Per-operation wall-clock budget.
    var requestTimeout: TimeInterval
    /// Built-in tools the managed run may use. Empty disables all tools —
    /// v1 JIRA operations are answered from the model plus configured MCP
    /// servers only.
    var allowedTools: [String]
    /// Dedicated working directory Console owns for these runs (created on
    /// prepare). Sessions launched here are Console's, not the user's.
    var workingDirectoryPath: String
    /// Bounded rotation for owned Claude session transcripts.
    var maxRetainedSessions: Int

    static let defaultMaxTurns = 8
    static let defaultRequestTimeout: TimeInterval = 60
    static let defaultMaxRetainedSessions = 20

    static var defaultWorkingDirectoryPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Console/ManagedClaude/workspace").path
    }

    init(
        model: String? = nil,
        maxTurns: Int = ManagedClaudeConfiguration.defaultMaxTurns,
        requestTimeout: TimeInterval = ManagedClaudeConfiguration.defaultRequestTimeout,
        allowedTools: [String] = [],
        workingDirectoryPath: String = ManagedClaudeConfiguration.defaultWorkingDirectoryPath,
        maxRetainedSessions: Int = ManagedClaudeConfiguration.defaultMaxRetainedSessions
    ) {
        self.model = model
        self.maxTurns = max(1, maxTurns)
        self.requestTimeout = max(1, requestTimeout)
        self.allowedTools = allowedTools
        self.workingDirectoryPath = workingDirectoryPath
        self.maxRetainedSessions = max(1, maxRetainedSessions)
    }

    /// Persists the configuration in Console's defaults. Contains no ticket
    /// data, no prompts, and no secrets.
    static func load(defaults: UserDefaults = .standard) -> ManagedClaudeConfiguration {
        guard let data = defaults.data(forKey: ManagedClaudeConfigurationStore.storageKey) else {
            return ManagedClaudeConfiguration()
        }
        return (try? JSONDecoder().decode(ManagedClaudeConfiguration.self, from: data)) ?? ManagedClaudeConfiguration()
    }

    func store(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: ManagedClaudeConfigurationStore.storageKey)
        }
    }
}

enum ManagedClaudeConfigurationStore {
    static let storageKey = "managedClaudeConfiguration"
}

// MARK: - Service errors

/// Errors surfaced by `ManagedClaudeService`. The distinction between
/// `launchFailed` (nothing ran) and `executionFailed`/`malformedOutput` (the
/// run dispatched and may have acted) is what lets JIRA writes decide between
/// safe retries and unknown-outcome reconciliation.
enum ClaudeServiceError: Error, Equatable, Sendable {
    /// No usable claude executable could be located.
    case executableUnavailable
    /// The service has not completed preparation (executable + flag checks).
    case notPrepared
    /// The installed CLI does not support flags the operation requires.
    case unsupportedFlags([String])
    /// The process could not be started. Nothing was dispatched.
    case launchFailed(reason: String)
    /// The operation ran past its deadline. It was dispatched and its outcome
    /// is unknown.
    case timedOut(correlationID: UUID)
    /// The waiting task was cancelled. The run was dispatched and its outcome
    /// is unknown.
    case cancelled
    /// Claude Code rejected the request for authentication reasons.
    case needsAuthentication(reason: String)
    /// The process ran but exited non-zero or reported an error result.
    case executionFailed(reason: String)
    /// The process exited successfully but the output was not a decodable
    /// structured envelope.
    case malformedOutput(reason: String)
    /// The service is shutting down; new operations are refused.
    case shuttingDown
}

// MARK: - Invocation and output

/// One headless Claude operation request. The prompt is memory-only: it is
/// piped to the child's stdin and never placed in process arguments,
/// environment, logs, or persistence.
struct ClaudeOperationInvocation: Sendable {
    let correlationID: UUID
    let prompt: String
    /// JSON Schema passed as `--json-schema` when supported by the installed
    /// CLI, validating the expected response shape.
    let expectedSchemaJSON: String?
    /// Explicitly owned session ID. Never derived from "latest conversation";
    /// `--continue` is never used by this service.
    let sessionID: UUID
    /// When true the run resumes `sessionID` (`--resume`); when false it
    /// starts a fresh run under that ID (`--session-id`).
    let resume: Bool
    /// When true the run persists no session on disk (`--no-session-persistence`).
    let ephemeral: Bool
    let modelOverride: String?
    let allowedToolsOverride: [String]?
    let toolPermissionRules: [String]
    let maxTurnsOverride: Int?
    let requiredFlags: Set<String>
    let deadline: Date

    init(
        correlationID: UUID = UUID(),
        prompt: String,
        expectedSchemaJSON: String? = nil,
        sessionID: UUID = UUID(),
        resume: Bool = false,
        ephemeral: Bool = true,
        modelOverride: String? = nil,
        allowedToolsOverride: [String]? = nil,
        toolPermissionRules: [String] = [],
        maxTurnsOverride: Int? = nil,
        requiredFlags: Set<String> = [],
        deadline: Date
    ) {
        self.correlationID = correlationID
        self.prompt = prompt
        self.expectedSchemaJSON = expectedSchemaJSON
        self.sessionID = sessionID
        self.resume = resume
        self.ephemeral = ephemeral
        self.modelOverride = modelOverride
        self.allowedToolsOverride = allowedToolsOverride
        self.toolPermissionRules = toolPermissionRules
        self.maxTurnsOverride = maxTurnsOverride
        self.requiredFlags = requiredFlags
        self.deadline = deadline
    }
}

/// Decoded, typed result of one managed headless run.
struct ClaudeOperationOutput: Equatable, Sendable {
    let correlationID: UUID
    let resultText: String?
    /// The session ID the CLI reports for the run, when present. Only ever
    /// recorded when Console supplied an explicit `--session-id`.
    let sessionID: UUID?
}

// MARK: - Lifecycle states

/// Observable lifecycle of the managed service, surfaced to Settings.
/// Deliberately coarse: it never embeds prompts, results, or ticket content.
enum ManagedClaudeServiceState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case busy
    case needsAuthentication
    case recovering
    case error(String)
}
