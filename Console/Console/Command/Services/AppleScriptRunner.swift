import Foundation
import AppKit

enum AppleScriptRunner {

    enum ScriptError: LocalizedError {
        case executionFailed(String)
        case invalidParameter(String)
        case permissionDenied(String)
        case timeout
        case emptyScript

        var errorDescription: String? {
            switch self {
            case .executionFailed(let msg): return "AppleScript failed: \(msg)"
            case .invalidParameter(let msg): return "Invalid parameter: \(msg)"
            case .permissionDenied(let msg): return "Permission denied: \(msg)"
            case .timeout: return "Script execution timed out"
            case .emptyScript: return "Script cannot be empty"
            }
        }
    }

    // MARK: - Application Control

    static func openApplication(
        name: String,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) async throws -> String {
        let sanitized = sanitizeAppName(name)
        guard !sanitized.isEmpty else {
            throw ScriptError.invalidParameter("Application name cannot be empty")
        }
        let script = """
        tell application "\(sanitized)"
            activate
        end tell
        """
        try await execute(script, processRunner: processRunner)
        return "Opened \(sanitized)"
    }

    static func quitApplication(
        name: String,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) async throws -> String {
        let sanitized = sanitizeAppName(name)
        guard !sanitized.isEmpty else {
            throw ScriptError.invalidParameter("Application name cannot be empty")
        }
        let script = """
        tell application "\(sanitized)"
            quit
        end tell
        """
        try await execute(script, processRunner: processRunner)
        return "Quit \(sanitized)"
    }

    // MARK: - System Controls

    static func setVolume(
        level: Int,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) async throws -> String {
        let clamped = min(max(level, 0), 100)
        try await execute("set volume output volume \(clamped)", processRunner: processRunner)
        return "Volume set to \(clamped)%"
    }

    static func toggleMute(processRunner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        let script = """
        set curVolume to output volume of (get volume settings)
        if curVolume is 0 then
            set volume output volume 50
        else
            set volume output volume 0
        end if
        """
        try await execute(script, processRunner: processRunner)
        return "Toggled mute"
    }

    static func toggleDarkMode(processRunner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        let beforeDark = try await isDarkMode(processRunner: processRunner)
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
        """
        try await execute(script, processRunner: processRunner)
        let afterDark = try await isDarkMode(processRunner: processRunner)
        if beforeDark == afterDark {
            throw ScriptError.executionFailed("Appearance did not change — grant Automation permission for System Events")
        }
        return afterDark ? "Switched to dark mode" : "Switched to light mode"
    }

    static func enableLightMode(processRunner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to false
            end tell
        end tell
        """
        try await execute(script, processRunner: processRunner)
        if try await isDarkMode(processRunner: processRunner) {
            throw ScriptError.executionFailed("Failed to switch to light mode — grant Automation permission for System Events")
        }
        return "Switched to light mode"
    }

    private static func isDarkMode(processRunner: any ProcessRunning) async throws -> Bool {
        let script = """
        tell application "System Events"
            tell appearance preferences
                return dark mode
            end tell
        end tell
        """
        let output = try await executeWithOutput(script, processRunner: processRunner)
        return output.lowercased().contains("true")
    }

    static func lockScreen(processRunner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        let script = """
        tell application "System Events" to keystroke "q" using {control down, command down}
        """
        try await execute(script, processRunner: processRunner)
        return "Screen locked"
    }

    static func emptyTrash(processRunner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        let script = """
        tell application "Finder"
            empty the trash
        end tell
        """
        try await execute(script, processRunner: processRunner)
        return "Trash emptied"
    }

    static func showDesktop(processRunner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        let script = """
        tell application "System Events"
            key code 103
        end tell
        """
        try await execute(script, processRunner: processRunner)
        return "Showing desktop"
    }

    static func openURL(
        _ urlString: String,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptError.invalidParameter("URL cannot be empty")
        }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        try await execute("open location \"\(escaped)\"", processRunner: processRunner)
        return "Opened URL: \(trimmed)"
    }

    static func typeText(
        _ text: String,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) async throws -> String {
        guard !text.isEmpty else {
            throw ScriptError.invalidParameter("Text cannot be empty")
        }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        try await execute(script, processRunner: processRunner)
        return "Typed text"
    }

    // MARK: - General Execution

    static func run(
        script source: String,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) async throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptError.emptyScript
        }
        return try await executeWithOutput(trimmed, processRunner: processRunner)
    }

    // MARK: - Private

    private static func execute(_ source: String, processRunner: any ProcessRunning) async throws {
        let result = try await executeProcess(source, processRunner: processRunner)
        if result.exitCode != 0 {
            let errorMsg = result.formattedStandardError.isEmpty ? "Unknown error" : result.formattedStandardError
            if errorMsg.contains("-1743") || errorMsg.contains("-10004") {
                throw ScriptError.permissionDenied(errorMsg)
            }
            throw ScriptError.executionFailed(errorMsg)
        }
    }

    private static func executeWithOutput(_ source: String, processRunner: any ProcessRunning) async throws -> String {
        let result = try await executeProcess(source, processRunner: processRunner)
        if result.exitCode != 0 {
            let errorMsg = result.formattedStandardError.isEmpty ? "Unknown error" : result.formattedStandardError
            if errorMsg.contains("-1743") || errorMsg.contains("-10004") {
                throw ScriptError.permissionDenied(errorMsg)
            }
            throw ScriptError.executionFailed(errorMsg)
        }
        return result.formattedStandardOutput.isEmpty
            ? "Script executed successfully"
            : result.formattedStandardOutput
    }

    private static func executeProcess(
        _ source: String,
        processRunner: any ProcessRunning
    ) async throws -> ProcessResult {
        do {
            return try await processRunner.run(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", source],
                workingDirectory: nil
            )
        } catch let error as ProcessRunError {
            throw ScriptError.executionFailed(error.localizedDescription)
        } catch let error as ScriptError {
            throw error
        } catch {
            throw ScriptError.executionFailed(error.localizedDescription)
        }
    }

    private static func sanitizeAppName(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
