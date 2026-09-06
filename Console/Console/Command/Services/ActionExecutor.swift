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

    func execute(_ action: CommandAction) async throws -> String {
        let payload = action.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            throw ActionExecutionError.invalidPayload("Payload is empty")
        }

        switch action.type {
        case .appIntent:
            return try await executeAppIntent(payload)
        case .appleScript:
            return try executeAppleScript(payload)
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
            return try AppleScriptRunner.openApplication(name: appName)

        case "quitapplication", "quit_application", "quitapp":
            let appName = parameter ?? payload
            return try AppleScriptRunner.quitApplication(name: appName)

        case "setvolume", "set_volume", "volume":
            guard let param = parameter, let level = Int(param) else {
                throw ActionExecutionError.invalidPayload("Volume level required")
            }
            return try AppleScriptRunner.setVolume(level: level)

        case "togglemute", "toggle_mute", "mute":
            return try AppleScriptRunner.toggleMute()

        case "toggledarkmode", "toggle_dark_mode", "darkmode":
            return try AppleScriptRunner.toggleDarkMode()

        case "enablelightmode", "enable_light_mode", "lightmode":
            return try AppleScriptRunner.enableLightMode()

        case "lockscreen", "lock_screen", "lock":
            return try AppleScriptRunner.lockScreen()

        case "showdesktop", "show_desktop", "desktop":
            return try AppleScriptRunner.showDesktop()

        case "emptytrash", "empty_trash", "trash":
            return try AppleScriptRunner.emptyTrash()

        case "openurl", "open_url", "url":
            guard let urlString = parameter else {
                throw ActionExecutionError.invalidPayload("URL required")
            }
            return try AppleScriptRunner.openURL(urlString)

        case "typetext", "type_text", "type":
            guard let text = parameter else {
                throw ActionExecutionError.invalidPayload("Text required")
            }
            return try AppleScriptRunner.typeText(text)

        default:
            throw ActionExecutionError.notImplemented("App Intent '\(intentName)' not yet supported")
        }
    }

    // MARK: - AppleScript Execution

    private func executeAppleScript(_ script: String) throws -> String {
        try AppleScriptRunner.run(script: script)
    }

    // MARK: - Shell Execution

    private func executeShell(_ payload: String) async throws -> String {
        let components = payload.components(separatedBy: " ")
        guard let command = components.first, !command.isEmpty else {
            throw ActionExecutionError.invalidPayload("Empty shell command")
        }

        let args = Array(components.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ActionExecutionError.shellError("Failed to launch: \(error.localizedDescription)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output.isEmpty ? "Command executed successfully" : output)
                } else {
                    let msg = errorOutput.isEmpty
                        ? "Exit code \(proc.terminationStatus)"
                        : errorOutput
                    continuation.resume(throwing: ActionExecutionError.shellError(msg))
                }
            }
        }
    }
}
