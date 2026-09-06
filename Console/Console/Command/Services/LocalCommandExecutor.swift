import Foundation
import AppKit
import SwiftData

extension Notification.Name {
    static let stopListeningRequested = Notification.Name("stopListeningRequested")
    static let stopExecutionRequested = Notification.Name("stopExecutionRequested")
    static let showCommandCreation = Notification.Name("showCommandCreation")
    static let globalHotkeyPressed = Notification.Name("globalHotkeyPressed")
    static let showNoteRequested = Notification.Name("showNoteRequested")
    static let voiceActivityDetected = Notification.Name("voiceActivityDetected")
}

@Observable
@MainActor
final class LocalCommandExecutor {
    private(set) var isExecuting = false
    private(set) var lastResult: ExecutionResult?
    private var cancelled = false
    private let actionExecutor: any CommandActionExecuting
    private let authorizer: any CommandAuthorizing
    private let validator: CommandValidator
    private let completionChecker = CompletionChecker()

    var modelContext: ModelContext?
    var onExecutionComplete: ((ExecutionResult) -> Void)?

    init(
        actionExecutor: (any CommandActionExecuting)? = nil,
        authorizer: (any CommandAuthorizing)? = nil,
        validator: CommandValidator = CommandValidator()
    ) {
        self.actionExecutor = actionExecutor ?? ActionExecutor()
        self.authorizer = authorizer ?? AuthorizationManager.shared
        self.validator = validator
    }

    private var failureBehavior: AppSettings.CommandFailureBehavior {
        let raw = UserDefaults.standard.string(forKey: "commandFailureBehavior")
            ?? AppSettings.CommandFailureBehavior.stopOnError.rawValue
        return AppSettings.CommandFailureBehavior(rawValue: raw) ?? .stopOnError
    }

    func cancelExecution() {
        cancelled = true
    }

    func execute(_ command: Command, skipAuthorization: Bool = false) async -> ExecutionResult {
        // Intercept Console internal commands
        if command.isConsole,
           let payload = command.actions.first?.payload,
           let action = ConsoleAction(rawValue: payload) {
            return await executeConsoleAction(action, command: command)
        }

        if !skipAuthorization, needsAuthorization(command) {
            let authorized = await authorizer.requestAuthorization(for: command)
            if !authorized {
                let deniedResult = ExecutionResult(
                    command: command,
                    logs: [],
                    overallSuccess: false,
                    totalDurationMs: 0,
                    authorizationDenied: true
                )
                lastResult = deniedResult
                VisualFeedbackService.shared.show(.warning("Authorization denied"))
                onExecutionComplete?(deniedResult)
                return deniedResult
            }
        }

        isExecuting = true
        cancelled = false

        let startTime = Date()
        let sortedActions = command.actions.sorted { $0.order < $1.order }
        var logs: [ExecutionLogEntry] = []
        var overallSuccess = true

        for (index, action) in sortedActions.enumerated() {
            if cancelled {
                overallSuccess = false
                break
            }

            let actionStart = Date()
            let result = await executeAction(action)
            let durationMs = Int(Date().timeIntervalSince(actionStart) * 1000)

            let entry = ExecutionLogEntry(
                timestamp: Date(),
                actionIndex: index,
                actionType: action.type,
                payload: action.payload,
                result: result,
                durationMs: durationMs
            )
            logs.append(entry)

            if !entry.isSuccess {
                overallSuccess = false
                if failureBehavior == .stopOnError {
                    break
                }
            }

            // Run completion check if present and action succeeded
            if entry.isSuccess, let check = action.completionCheck {
                let timeout = TimeInterval(action.timeoutMS) / 1000.0
                let passed = await completionChecker.waitForCompletion(check, timeout: timeout)
                if !passed {
                    overallSuccess = false
                    if failureBehavior == .stopOnError { break }
                }
            }

            // Post-action delay
            if entry.isSuccess, action.delayAfterMS > 0 {
                try? await Task.sleep(nanoseconds: UInt64(action.delayAfterMS) * 1_000_000)
            }
        }

        let wasCancelled = cancelled
        let totalDuration = Int(Date().timeIntervalSince(startTime) * 1000)
        let executionResult = ExecutionResult(
            command: command,
            logs: logs,
            overallSuccess: overallSuccess,
            totalDurationMs: totalDuration
        )

        lastResult = executionResult
        isExecuting = false
        cancelled = false

        if wasCancelled {
            VisualFeedbackService.shared.show(.warning("Execution stopped"))
        } else {
            playCompletionSound(success: overallSuccess)
            showCompletionBanner(command: command, success: overallSuccess, logs: logs)
        }
        onExecutionComplete?(executionResult)

        return executionResult
    }

    // MARK: - Console Actions

    private func executeConsoleAction(_ action: ConsoleAction, command: Command) async -> ExecutionResult {
        let startTime = Date()

        switch action {
        case .showRecentCommands:
            ConsoleNavigation.showTerminal(tab: .myCommands)
            ConsoleWindowManager.bringToFront("main")

        case .fishOff:
            NotificationCenter.default.post(name: .stopListeningRequested, object: nil)

        case .fishSettings:
            ConsoleNavigation.showSettings()
            ConsoleWindowManager.bringToFront("main")

        case .fishBeQuiet:
            UserDefaults.standard.set(false, forKey: "soundFeedbackEnabled")
            UserDefaults.standard.synchronize()

        case .fishMakeNoise:
            UserDefaults.standard.set(true, forKey: "soundFeedbackEnabled")
            UserDefaults.standard.synchronize()
            SoundFeedbackService.shared.previewCue(.happyFish)

        case .newCommand:
            ConsoleNavigation.showTerminal(tab: .myCommands)
            ConsoleWindowManager.bringToFront("main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .showCommandCreation, object: nil)
            }

        case .fishNote:
            NotificationCenter.default.post(name: .showNoteRequested, object: nil)
        }

        let result = ExecutionResult(
            command: command,
            logs: [],
            overallSuccess: true,
            totalDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
        lastResult = result
        onExecutionComplete?(result)
        return result
    }

    // MARK: - Authorization

    private func needsAuthorization(_ command: Command) -> Bool {
        if UserDefaults.standard.bool(forKey: "requireAuthorizationForAllCommands") {
            return true
        }

        let confirmationEnabled = UserDefaults.standard.object(forKey: "requireConfirmationForDangerous") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "requireConfirmationForDangerous")
        guard confirmationEnabled else { return false }

        return validator.needsConfirmation(command)
    }

    // MARK: - Action Dispatch

    private func executeAction(_ action: CommandAction) async -> Result<String, Error> {
        // Handle app-level intents that require UI context
        if action.type == .appIntent, let result = await handleAppLevelIntent(action.payload) {
            return result
        }

        do {
            let output = try await actionExecutor.execute(action)
            return .success(output)
        } catch {
            return .failure(error)
        }
    }

    // Intents that interact with the app UI rather than external systems
    private func handleAppLevelIntent(_ payload: String) async -> Result<String, Error>? {
        let intentName = payload.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? payload

        switch intentName.lowercased() {
        case "showsettings", "show_settings", "settings", "opensettings":
            ConsoleWindowManager.bringToFront("main")
            return .success("Settings opened")

        case "stoplistening", "stop_listening":
            NotificationCenter.default.post(name: .stopListeningRequested, object: nil)
            return .success("Listening stopped")

        case "stopexecution", "stop_execution", "stop":
            NotificationCenter.default.post(name: .stopExecutionRequested, object: nil)
            return .success("Execution stopped")

        default:
            return nil
        }
    }

    // MARK: - Feedback

    private func playCompletionSound(success: Bool) {
        let event: SoundFeedbackEvent = success ? .allCommandsCompleted : .commandNotRecognized
        SoundFeedbackService.shared.play(event)
    }

    private func showCompletionBanner(command: Command, success: Bool, logs: [ExecutionLogEntry]) {
        if success {
            VisualFeedbackService.shared.show(.commandRecognized(command.name))
        } else {
            let errorMsg = logs.first(where: { !$0.isSuccess })?.message ?? "Unknown error"
            VisualFeedbackService.shared.show(.commandFailure(command.name, errorMsg))
        }
    }

}
