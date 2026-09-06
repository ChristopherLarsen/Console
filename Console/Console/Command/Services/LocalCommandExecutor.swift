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

@MainActor
protocol CommandRunning: AnyObject {
    var isExecuting: Bool { get }
    func execute(_ command: Command, skipAuthorization: Bool) async -> CommandRun
    func cancelExecution()
}

@Observable
@MainActor
final class LocalCommandExecutor: CommandRunning {
    private(set) var isExecuting = false
    private(set) var lastResult: ExecutionResult?
    private(set) var activeRunID: UUID?
    private(set) var lastRunID: UUID?
    private(set) var completedRunCount = 0
    private var cancelled = false
    private var activeExecutionTask: Task<CommandRun, Never>?
    private let actionExecutor: any CommandActionExecuting
    private let authorizer: any CommandAuthorizing
    private let validator: CommandValidator
    private let completionChecker = CompletionChecker()

    var modelContext: ModelContext?

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
        activeExecutionTask?.cancel()
    }

    func execute(_ command: Command, skipAuthorization: Bool = false) async -> CommandRun {
        if let busy = rejectIfOccupied(command) {
            return busy
        }

        let runID = beginRun()
        let task = Task { @MainActor in
            await self.performExecute(command, runID: runID, skipAuthorization: skipAuthorization)
        }
        activeExecutionTask = task
        if cancelled {
            task.cancel()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private var shouldHalt: Bool {
        cancelled || Task.isCancelled
    }

    private func performExecute(
        _ command: Command,
        runID: UUID,
        skipAuthorization: Bool
    ) async -> CommandRun {
        if command.isConsole,
           let payload = command.actions.first?.payload,
           let action = ConsoleAction(rawValue: payload) {
            let result = await executeConsoleAction(action, command: command)
            let run = CommandRun(id: runID, result: result)
            endRun(run, feedback: .silent)
            return run
        }

        if shouldHalt {
            return finishCancelled(command, runID: runID, logs: [], startTime: Date())
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
                let run = CommandRun(id: runID, result: deniedResult)
                endRun(run, feedback: .denied)
                return run
            }
            if shouldHalt {
                return finishCancelled(command, runID: runID, logs: [], startTime: Date())
            }
        }

        let startTime = Date()
        let sortedActions = command.actions.sorted { $0.order < $1.order }
        var logs: [ExecutionLogEntry] = []
        var overallSuccess = true

        for (index, action) in sortedActions.enumerated() {
            if shouldHalt {
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

            if shouldHalt {
                overallSuccess = false
                break
            }

            if !entry.isSuccess {
                overallSuccess = false
                if failureBehavior == .stopOnError {
                    break
                }
            }

            if entry.isSuccess, let check = action.completionCheck {
                let timeout = TimeInterval(action.timeoutMS) / 1000.0
                let passed = await completionChecker.waitForCompletion(check, timeout: timeout)
                if shouldHalt {
                    overallSuccess = false
                    break
                }
                if !passed {
                    overallSuccess = false
                    if failureBehavior == .stopOnError { break }
                }
            }

            if entry.isSuccess, action.delayAfterMS > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(action.delayAfterMS) * 1_000_000)
                } catch {
                    overallSuccess = false
                    break
                }
                if shouldHalt {
                    overallSuccess = false
                    break
                }
            }
        }

        let wasCancelled = cancelled || Task.isCancelled
        let totalDuration = Int(Date().timeIntervalSince(startTime) * 1000)
        let executionResult = ExecutionResult(
            command: command,
            logs: logs,
            overallSuccess: overallSuccess && !wasCancelled,
            totalDurationMs: totalDuration
        )
        let run = CommandRun(id: runID, result: executionResult)
        endRun(run, feedback: wasCancelled ? .cancelled : .finished(success: overallSuccess, command: command, logs: logs))
        return run
    }

    private func finishCancelled(
        _ command: Command,
        runID: UUID,
        logs: [ExecutionLogEntry],
        startTime: Date
    ) -> CommandRun {
        let executionResult = ExecutionResult(
            command: command,
            logs: logs,
            overallSuccess: false,
            totalDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
        let run = CommandRun(id: runID, result: executionResult)
        endRun(run, feedback: .cancelled)
        return run
    }

    private func rejectIfOccupied(_ command: Command) -> CommandRun? {
        guard isExecuting || activeRunID != nil else { return nil }
        VisualFeedbackService.shared.show(.warning(CommandRun.alreadyRunningMessage))
        return CommandRun.alreadyRunning(command: command)
    }

    private func beginRun() -> UUID {
        let runID = UUID()
        activeRunID = runID
        isExecuting = true
        cancelled = false
        return runID
    }

    private func endRun(_ run: CommandRun, feedback: RunFeedback) {
        guard activeRunID == run.id else { return }
        lastResult = run.result
        lastRunID = run.id
        isExecuting = false
        cancelled = false
        activeRunID = nil
        activeExecutionTask = nil
        completedRunCount += 1

        switch feedback {
        case .cancelled:
            VisualFeedbackService.shared.show(.warning("Execution stopped"))
        case .denied:
            VisualFeedbackService.shared.show(.warning("Authorization denied"))
        case .finished(let success, let command, let logs):
            playCompletionSound(success: success)
            showCompletionBanner(command: command, success: success, logs: logs)
        case .silent:
            break
        }
    }

    private enum RunFeedback {
        case finished(success: Bool, command: Command, logs: [ExecutionLogEntry])
        case cancelled
        case denied
        case silent
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

        return ExecutionResult(
            command: command,
            logs: [],
            overallSuccess: true,
            totalDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
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
        if shouldHalt {
            return .failure(ActionExecutionError.cancelled)
        }

        if action.type == .appIntent, let result = await handleAppLevelIntent(action.payload) {
            return result
        }

        do {
            let output = try await actionExecutor.execute(action)
            return .success(output)
        } catch is CancellationError {
            return .failure(ActionExecutionError.cancelled)
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
