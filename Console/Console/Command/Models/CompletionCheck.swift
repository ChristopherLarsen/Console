import Foundation

struct CompletionCheck: Codable, Hashable {
    let type: CompletionCheckType
    let value: String
}

enum CompletionCheckType: String, Codable, Sendable {
    case appRunning
    case fileExists
    case windowTitle
    case delay
}

enum CompletionCheckOutcome: String, Equatable, Sendable {
    case passed
    case timedOut
    case failed
    case cancelled
}

struct CompletionCheckRun: Equatable, Sendable {
    let type: CompletionCheckType
    let value: String
    let elapsedMs: Int
    let outcome: CompletionCheckOutcome

    var passedMessage: String {
        "Completion check passed: \(type.rawValue) '\(value)' (\(elapsedMs)ms)"
    }
}

enum CompletionCheckError: LocalizedError, Equatable {
    case timedOut(type: CompletionCheckType, value: String, timeoutMS: Int, elapsedMs: Int)
    case failed(type: CompletionCheckType, value: String, elapsedMs: Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let type, let value, let timeoutMS, let elapsedMs):
            return "Completion check timed out: \(type.rawValue) '\(value)' did not succeed within \(timeoutMS)ms (waited \(elapsedMs)ms)"
        case .failed(let type, let value, let elapsedMs):
            return "Completion check failed: \(type.rawValue) '\(value)' after \(elapsedMs)ms"
        }
    }
}

// MARK: - Factory Methods

extension CompletionCheck {
    static func appRunning(_ bundleID: String) -> CompletionCheck {
        CompletionCheck(type: .appRunning, value: bundleID)
    }

    static func fileExists(_ path: String) -> CompletionCheck {
        CompletionCheck(type: .fileExists, value: path)
    }

    static func windowTitle(_ title: String) -> CompletionCheck {
        CompletionCheck(type: .windowTitle, value: title)
    }

    static func delay(milliseconds: Int) -> CompletionCheck {
        CompletionCheck(type: .delay, value: String(milliseconds))
    }
}
