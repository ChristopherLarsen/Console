import Foundation
import AppKit

// MARK: - Execution Errors

enum ActionExecutionError: LocalizedError {
    case invalidPayload(String)
    case unsupportedActionType(String)
    case appleScriptError(String)
    case shellError(String)
    case timeout(String)
    case cancelled
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let msg): return "Invalid payload: \(msg)"
        case .unsupportedActionType(let msg): return "Unsupported action type: \(msg)"
        case .appleScriptError(let msg): return "AppleScript error: \(msg)"
        case .shellError(let msg): return "Shell error: \(msg)"
        case .timeout(let msg): return "Timeout: \(msg)"
        case .cancelled: return "Execution stopped"
        case .notImplemented(let msg): return "Not implemented: \(msg)"
        }
    }
}

// MARK: - Action Executor

protocol CommandActionExecuting: AnyObject {
    func execute(_ action: CommandAction) async throws -> String
}

final class ActionExecutor: CommandActionExecuting {

    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func execute(_ action: CommandAction) async throws -> String {
        let payload = action.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            throw ActionExecutionError.invalidPayload("Payload is empty")
        }

        let runner = DeadlineBoundProcessRunner(
            base: processRunner,
            deadline: Self.deadline(for: action)
        )

        switch action.type {
        case .appIntent:
            return try await executeAppIntent(payload, processRunner: runner)
        case .appleScript:
            return try await executeAppleScript(payload, processRunner: runner)
        case .shell:
            return try await executeShell(payload, processRunner: runner, timeoutMS: action.timeoutMS)
        }
    }

    static func deadline(for action: CommandAction) -> Date? {
        guard action.timeoutMS > 0 else { return nil }
        return Date().addingTimeInterval(TimeInterval(action.timeoutMS) / 1000.0)
    }

    // MARK: - App Intent Execution

    private func executeAppIntent(_ payload: String, processRunner: any ProcessRunning) async throws -> String {
        let components = payload.split(separator: ":", maxSplits: 1).map(String.init)
        let intentName = components.first ?? payload
        let parameter = components.count > 1 ? components[1] : nil

        switch intentName.lowercased() {
        case "openapplication", "open_application", "openapp":
            let appName = parameter ?? payload
            return try await AppleScriptRunner.openApplication(name: appName, processRunner: processRunner)

        case "quitapplication", "quit_application", "quitapp":
            let appName = parameter ?? payload
            return try await AppleScriptRunner.quitApplication(name: appName, processRunner: processRunner)

        case "setvolume", "set_volume", "volume":
            guard let param = parameter, let level = Int(param) else {
                throw ActionExecutionError.invalidPayload("Volume level required")
            }
            return try await AppleScriptRunner.setVolume(level: level, processRunner: processRunner)

        case "togglemute", "toggle_mute", "mute":
            return try await AppleScriptRunner.toggleMute(processRunner: processRunner)

        case "toggledarkmode", "toggle_dark_mode", "darkmode":
            return try await AppleScriptRunner.toggleDarkMode(processRunner: processRunner)

        case "enablelightmode", "enable_light_mode", "lightmode":
            return try await AppleScriptRunner.enableLightMode(processRunner: processRunner)

        case "lockscreen", "lock_screen", "lock":
            return try await AppleScriptRunner.lockScreen(processRunner: processRunner)

        case "showdesktop", "show_desktop", "desktop":
            return try await AppleScriptRunner.showDesktop(processRunner: processRunner)

        case "emptytrash", "empty_trash", "trash":
            return try await AppleScriptRunner.emptyTrash(processRunner: processRunner)

        case "openurl", "open_url", "url":
            guard let urlString = parameter else {
                throw ActionExecutionError.invalidPayload("URL required")
            }
            return try await AppleScriptRunner.openURL(urlString, processRunner: processRunner)

        case "typetext", "type_text", "type":
            guard let text = parameter else {
                throw ActionExecutionError.invalidPayload("Text required")
            }
            return try await AppleScriptRunner.typeText(text, processRunner: processRunner)

        default:
            throw ActionExecutionError.notImplemented("App Intent '\(intentName)' not yet supported")
        }
    }

    // MARK: - AppleScript Execution

    private func executeAppleScript(_ script: String, processRunner: any ProcessRunning) async throws -> String {
        do {
            return try await AppleScriptRunner.run(script: script, processRunner: processRunner)
        } catch is CancellationError {
            throw ActionExecutionError.cancelled
        } catch let error as ProcessRunError {
            throw mapProcessError(error, timeoutMS: nil)
        } catch let error as AppleScriptRunner.ScriptError {
            switch error {
            case .timeout:
                throw ActionExecutionError.timeout(error.localizedDescription)
            default:
                throw ActionExecutionError.appleScriptError(error.localizedDescription)
            }
        } catch let error as ActionExecutionError {
            throw error
        } catch {
            throw ActionExecutionError.appleScriptError(error.localizedDescription)
        }
    }

    // MARK: - Shell Execution

    private func executeShell(
        _ payload: String,
        processRunner: any ProcessRunning,
        timeoutMS: Int
    ) async throws -> String {
        let launch: ProcessLaunchSpec
        do {
            launch = try ShellPayload.resolve(payload).processLaunch
        } catch {
            throw ActionExecutionError.invalidPayload(error.localizedDescription)
        }

        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executablePath: launch.executablePath,
                arguments: launch.arguments,
                workingDirectory: launch.workingDirectory
            )
        } catch is CancellationError {
            throw ActionExecutionError.cancelled
        } catch let error as ProcessRunError {
            throw mapProcessError(error, timeoutMS: timeoutMS)
        } catch let error as ActionExecutionError {
            throw error
        } catch {
            throw ActionExecutionError.shellError("Failed to launch: \(error.localizedDescription)")
        }

        let output = result.formattedStandardOutput
        let errorOutput = result.formattedStandardError

        if result.exitCode == 0 {
            return output.isEmpty ? "Command executed successfully" : output
        }
        let msg = errorOutput.isEmpty
            ? "Exit code \(result.exitCode)"
            : errorOutput
        throw ActionExecutionError.shellError(msg)
    }

    private func mapProcessError(_ error: ProcessRunError, timeoutMS: Int?) -> ActionExecutionError {
        switch error {
        case .timedOut:
            if let timeoutMS, timeoutMS > 0 {
                return .timeout("Action exceeded \(timeoutMS)ms")
            }
            return .timeout(error.localizedDescription)
        case .cancelled:
            return .cancelled
        case .executableMissing, .launchFailed:
            return .shellError(error.localizedDescription)
        }
    }
}

/// Applies an action deadline to every process launch for one execution.
struct DeadlineBoundProcessRunner: ProcessRunning {
    let base: any ProcessRunning
    let deadline: Date?

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        try await base.run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            deadline: earlier(self.deadline, deadline)
        )
    }

    private func earlier(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case (let a?, let b?): return min(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }
}
