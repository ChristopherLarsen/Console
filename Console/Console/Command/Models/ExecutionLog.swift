import Foundation

struct ExecutionLogEntry: Identifiable {
    enum Kind: Equatable {
        case action
        case completionCheck
    }

    let id = UUID()
    let timestamp: Date
    let actionIndex: Int
    let actionType: CommandActionType
    let payload: String
    let result: Result<String, Error>
    let durationMs: Int
    let kind: Kind
    let completionCheck: CompletionCheckRun?

    init(
        timestamp: Date,
        actionIndex: Int,
        actionType: CommandActionType,
        payload: String,
        result: Result<String, Error>,
        durationMs: Int,
        kind: Kind = .action,
        completionCheck: CompletionCheckRun? = nil
    ) {
        self.timestamp = timestamp
        self.actionIndex = actionIndex
        self.actionType = actionType
        self.payload = payload
        self.result = result
        self.durationMs = durationMs
        self.kind = kind
        self.completionCheck = completionCheck
    }

    var isSuccess: Bool {
        if case .success = result { return true }
        return false
    }

    var message: String {
        switch result {
        case .success(let output): return output
        case .failure(let error): return error.localizedDescription
        }
    }
}

struct ExecutionResult {
    let command: Command
    let logs: [ExecutionLogEntry]
    let overallSuccess: Bool
    let totalDurationMs: Int
    var authorizationDenied: Bool = false
    var alreadyRunning: Bool = false
    var wasCancelled: Bool = false

    var failedSteps: [ExecutionLogEntry] {
        logs.filter { !$0.isSuccess }
    }

    /// Banner text for a failed run. A missing failed row used to surface as
    /// "Unknown error" when only a completion check had failed.
    static func failureBannerMessage(from logs: [ExecutionLogEntry]) -> String {
        logs.first(where: { !$0.isSuccess })?.message ?? "Unknown error"
    }

    var failureBannerMessage: String {
        Self.failureBannerMessage(from: logs)
    }
}

struct CommandRun: Identifiable {
    static let alreadyRunningMessage = "A command is already running"

    let id: UUID
    let result: ExecutionResult

    static func alreadyRunning(command: Command) -> CommandRun {
        CommandRun(
            id: UUID(),
            result: ExecutionResult(
                command: command,
                logs: [],
                overallSuccess: false,
                totalDurationMs: 0,
                alreadyRunning: true
            )
        )
    }
}
