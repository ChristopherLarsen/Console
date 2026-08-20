import Foundation
import AppKit

// MARK: - Pipeline Result

enum PipelineResult {
    case success(duration: TimeInterval, log: [String])
    case failed(error: String, atAction: Int, log: [String])
    case timeout(atAction: Int, log: [String])
    case cancelled(atAction: Int, log: [String])

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var log: [String] {
        switch self {
        case .success(_, let log),
             .failed(_, _, let log),
             .timeout(_, let log),
             .cancelled(_, let log):
            return log
        }
    }
}

// MARK: - Execution Context

final class ExecutionContext {
    let commandID: UUID
    let startTime: Date
    var currentAction: Int = 0
    var state: ExecutionState = .preparing
    private(set) var logEntries: [String] = []

    enum ExecutionState {
        case preparing
        case executing
        case completed
        case failed
    }

    init(commandID: UUID) {
        self.commandID = commandID
        self.startTime = Date()
    }

    func log(_ message: String) {
        let timestamp = Date().timeIntervalSince(startTime)
        let entry = String(format: "[%.3fs] %@", timestamp, message)
        logEntries.append(entry)
    }

    var fullLog: [String] { logEntries }
}

// MARK: - Cancellation Token

final class CancellationToken: @unchecked Sendable {
    private var _isCancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

// MARK: - Command Executor

final class CommandExecutor {
    private let validator = CommandValidator()
    private let actionExecutor = ActionExecutor()
    private let completionChecker = CompletionChecker()
    private var cancellationToken: CancellationToken?

    func execute(_ command: Command) async -> PipelineResult {
        let validation = validator.validateCommand(command)
        switch validation {
        case .success:
            break
        case .failure(let error):
            return .failed(error: error, atAction: -1, log: ["Validation failed: \(error)"])
        case .requiresConfirmation(let message, severity: let severity):
            let confirmed = await requestConfirmation(message: message, severity: severity)
            if !confirmed {
                return .cancelled(atAction: -1, log: ["User cancelled: \(message)"])
            }
        }

        let context = ExecutionContext(commandID: command.id)
        cancellationToken = CancellationToken()
        context.log("Starting execution: \(command.name)")

        let sortedActions = command.actions.sorted { $0.order < $1.order }

        for (index, action) in sortedActions.enumerated() {
            if cancellationToken?.isCancelled == true {
                context.log("Cancelled by user")
                return .cancelled(atAction: index, log: context.fullLog)
            }

            context.currentAction = index
            context.state = .executing
            context.log("Action \(index): \(action.actionDescription)")

            // Execute with retry logic
            var lastError: Error?
            var attempts = 0
            let maxAttempts = action.retryOnFailure ? (action.maxRetries ?? 3) : 1

            while attempts < maxAttempts {
                attempts += 1
                if attempts > 1 {
                    context.log("Retry \(attempts)/\(maxAttempts)")
                    let backoff = TimeInterval(1 << (attempts - 2))
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }

                do {
                    let result = try await actionExecutor.execute(action)
                    context.log("Action \(index) succeeded: \(result)")
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    context.log("Action \(index) failed (attempt \(attempts)): \(error.localizedDescription)")
                }
            }

            // Handle failure with optional fallback
            if let error = lastError {
                if let fallback = action.fallbackAction {
                    context.log("Trying fallback for action \(index)")
                    let fallbackCommandAction = CommandAction(
                        type: fallback.type,
                        payload: fallback.payload
                    )
                    do {
                        let fallbackResult = try await actionExecutor.execute(fallbackCommandAction)
                        context.log("Fallback succeeded: \(fallbackResult)")
                    } catch let fallbackError {
                        context.log("Fallback failed: \(fallbackError.localizedDescription)")
                        context.state = .failed
                        return .failed(
                            error: "Action \(index) and fallback both failed: \(fallbackError.localizedDescription)",
                            atAction: index,
                            log: context.fullLog
                        )
                    }
                } else {
                    context.state = .failed
                    return .failed(
                        error: error.localizedDescription,
                        atAction: index,
                        log: context.fullLog
                    )
                }
            }

            // Post-action delay
            if action.delayAfterMS > 0 {
                context.log("Waiting \(action.delayAfterMS)ms")
                try? await Task.sleep(nanoseconds: UInt64(action.delayAfterMS) * 1_000_000)
            }

            // Completion check
            if let check = action.completionCheck {
                context.log("Completion check: \(check.type.rawValue) = '\(check.value)'")
                let timeout = TimeInterval(action.timeoutMS) / 1000.0
                let passed = await completionChecker.waitForCompletion(check, timeout: timeout)
                if !passed {
                    context.log("Completion check timed out after \(action.timeoutMS)ms")
                    return .timeout(atAction: index, log: context.fullLog)
                }
                context.log("Completion check passed")
            }
        }

        context.state = .completed
        let duration = Date().timeIntervalSince(context.startTime)
        context.log("Completed in \(String(format: "%.2f", duration))s")
        return .success(duration: duration, log: context.fullLog)
    }

    func cancel() {
        cancellationToken?.cancel()
    }

    // MARK: - Confirmation

    @MainActor
    private func showConfirmationAlert(message: String, severity: ConfirmationSeverity) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Confirm Command Execution"
        alert.informativeText = message
        alert.alertStyle = severity == .high ? .critical : .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")

        if severity == .high {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = "Type 'CONFIRM' to proceed"
            alert.accessoryView = input

            let response = alert.runModal()
            return response == .alertFirstButtonReturn
                && input.stringValue.uppercased() == "CONFIRM"
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requestConfirmation(message: String, severity: ConfirmationSeverity) async -> Bool {
        showConfirmationAlert(message: message, severity: severity)
    }
}
