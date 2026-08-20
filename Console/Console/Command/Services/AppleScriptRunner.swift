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

    static func openApplication(name: String) throws -> String {
        let sanitized = sanitizeAppName(name)
        guard !sanitized.isEmpty else {
            throw ScriptError.invalidParameter("Application name cannot be empty")
        }
        let script = """
        tell application "\(sanitized)"
            activate
        end tell
        """
        try execute(script)
        return "Opened \(sanitized)"
    }

    static func quitApplication(name: String) throws -> String {
        let sanitized = sanitizeAppName(name)
        guard !sanitized.isEmpty else {
            throw ScriptError.invalidParameter("Application name cannot be empty")
        }
        let script = """
        tell application "\(sanitized)"
            quit
        end tell
        """
        try execute(script)
        return "Quit \(sanitized)"
    }

    // MARK: - System Controls

    static func setVolume(level: Int) throws -> String {
        let clamped = min(max(level, 0), 100)
        try execute("set volume output volume \(clamped)")
        return "Volume set to \(clamped)%"
    }

    static func toggleMute() throws -> String {
        let script = """
        set curVolume to output volume of (get volume settings)
        if curVolume is 0 then
            set volume output volume 50
        else
            set volume output volume 0
        end if
        """
        try execute(script)
        return "Toggled mute"
    }

    static func toggleDarkMode() throws -> String {
        let beforeDark = try isDarkMode()
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
        """
        try execute(script)
        let afterDark = try isDarkMode()
        if beforeDark == afterDark {
            throw ScriptError.executionFailed("Appearance did not change — grant Automation permission for System Events")
        }
        return afterDark ? "Switched to dark mode" : "Switched to light mode"
    }

    static func enableLightMode() throws -> String {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to false
            end tell
        end tell
        """
        try execute(script)
        if try isDarkMode() {
            throw ScriptError.executionFailed("Failed to switch to light mode — grant Automation permission for System Events")
        }
        return "Switched to light mode"
    }

    // Reads current appearance state from System Events
    private static func isDarkMode() throws -> Bool {
        let script = """
        tell application "System Events"
            tell appearance preferences
                return dark mode
            end tell
        end tell
        """
        let output = try executeWithOutput(script)
        return output.lowercased().contains("true")
    }

    static func lockScreen() throws -> String {
        let script = """
        tell application "System Events" to keystroke "q" using {control down, command down}
        """
        try execute(script)
        return "Screen locked"
    }

    static func emptyTrash() throws -> String {
        let script = """
        tell application "Finder"
            empty the trash
        end tell
        """
        try execute(script)
        return "Trash emptied"
    }

    static func showDesktop() throws -> String {
        let script = """
        tell application "System Events"
            key code 103
        end tell
        """
        try execute(script)
        return "Showing desktop"
    }

    static func openURL(_ urlString: String) throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptError.invalidParameter("URL cannot be empty")
        }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        try execute("open location \"\(escaped)\"")
        return "Opened URL: \(trimmed)"
    }

    static func typeText(_ text: String) throws -> String {
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
        try execute(script)
        return "Typed text"
    }

    // MARK: - General Execution

    static func run(script source: String) throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptError.emptyScript
        }
        return try executeWithOutput(trimmed)
    }

    // MARK: - Private

    private static func execute(_ source: String) throws {
        let result = try executeProcess(source)
        if result.exitCode != 0 {
            let errorMsg = result.stderr.isEmpty ? "Unknown error" : result.stderr
            if errorMsg.contains("-1743") || errorMsg.contains("-10004") {
                throw ScriptError.permissionDenied(errorMsg)
            }
            throw ScriptError.executionFailed(errorMsg)
        }
    }

    private static func executeWithOutput(_ source: String) throws -> String {
        let result = try executeProcess(source)
        if result.exitCode != 0 {
            let errorMsg = result.stderr.isEmpty ? "Unknown error" : result.stderr
            if errorMsg.contains("-1743") || errorMsg.contains("-10004") {
                throw ScriptError.permissionDenied(errorMsg)
            }
            throw ScriptError.executionFailed(errorMsg)
        }
        return result.stdout.isEmpty ? "Script executed successfully" : result.stdout
    }

    private static func executeProcess(_ source: String) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (stdout, stderr, process.terminationStatus)
    }

    private static func sanitizeAppName(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
