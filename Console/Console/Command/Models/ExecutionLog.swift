import Foundation

struct ExecutionLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let actionIndex: Int
    let actionType: CommandActionType
    let payload: String
    let result: Result<String, Error>
    let durationMs: Int

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

    var failedSteps: [ExecutionLogEntry] {
        logs.filter { !$0.isSuccess }
    }
}
