import Foundation

enum MenuBarError: LocalizedError {
    case executionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .executionFailed(let reason): return "Execution failed: \(reason)"
        case .timeout: return "Operation timed out"
        }
    }
}
