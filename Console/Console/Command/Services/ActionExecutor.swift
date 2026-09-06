import Foundation
import AppKit

// MARK: - Execution Errors

enum ActionExecutionError: LocalizedError {
    case invalidPayload(String)
    case unsupportedActionType(String)
    case appleScriptError(String)
    case shellError(String)
    case timeout(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let msg): return "Invalid payload: \(msg)"
        case .unsupportedActionType(let msg): return "Unsupported action type: \(msg)"
        case .appleScriptError(let msg): return "AppleScript error: \(msg)"
        case .shellError(let msg): return "Shell error: \(msg)"
        case .timeout(let msg): return "Timeout: \(msg)"
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

        switch action.type {
        case .appIntent:
            return try await executeAppIntent(payload)
        case .appleScript:
            return try await executeAppleScript(payload)
        case .shell:
            return try await executeShell(payload)
        }
    }

    // MARK: - App Intent Execution

    private func executeAppIntent(_ payload: String) async throws -> String {
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

    private func executeAppleScript(_ script: String) async throws -> String {
        try await AppleScriptRunner.run(script: script, processRunner: processRunner)
    }

    // MARK: - Shell Execution

    private func executeShell(_ payload: String) async throws -> String {
        let components = payload.components(separatedBy: " ")
        guard let command = components.first, !command.isEmpty else {
            throw ActionExecutionError.invalidPayload("Empty shell command")
        }

        let args = Array(components.dropFirst())
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executablePath: "/usr/bin/env",
                arguments: [command] + args,
                workingDirectory: nil
            )
        } catch let error as ProcessRunError {
            throw ActionExecutionError.shellError(error.localizedDescription)
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
}
