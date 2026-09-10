import Foundation
import AppKit

enum ValidationResult {
    case success
    case failure(String)
    case requiresConfirmation(String, severity: ConfirmationSeverity)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum ConfirmationSeverity {
    case low
    case medium
    case high
}

struct CommandValidator {
    private let fileManager = FileManager.default

    func validateCommand(_ command: Command) -> ValidationResult {
        for action in command.actions {
            if !isValidActionType(action) {
                return .failure("Unsupported action type: \(action.type.rawValue)")
            }
            if let fallback = action.fallbackAction {
                let fallbackCommand = fallback.asCommandAction(timeoutMS: action.timeoutMS)
                if !isValidActionType(fallbackCommand) {
                    return .failure("Unsupported fallback action type: \(fallback.type.rawValue)")
                }
            }
        }

        for (index, action) in command.actions.enumerated() {
            if let error = validatePayload(action) {
                return .failure("Action \(index + 1): \(error)")
            }
            if let fallback = action.fallbackAction {
                let fallbackCommand = fallback.asCommandAction(timeoutMS: action.timeoutMS)
                if let error = validatePayload(fallbackCommand) {
                    return .failure("Action \(index + 1) fallback: \(error)")
                }
            }
            if let message = ActionAttemptPolicy.retryLimitValidationMessage(
                retryOnFailure: action.retryOnFailure,
                maxRetries: action.maxRetries
            ) {
                return .failure("Action \(index + 1): \(message)")
            }
        }

        if let danger = detectDangerousOperation(command) {
            return .requiresConfirmation(danger.message, severity: danger.severity)
        }

        for action in command.actions {
            if action.delayAfterMS < 0 || action.delayAfterMS > 60000 {
                return .failure("Invalid delay: \(action.delayAfterMS)ms (must be 0–60000)")
            }
            if action.timeoutMS < 0 || action.timeoutMS > 300000 {
                return .failure("Invalid timeout: \(action.timeoutMS)ms (must be 0–300000)")
            }
        }

        return .success
    }

    /// True when the command is flagged for confirmation or its payloads match a known dangerous pattern.
    func needsConfirmation(_ command: Command) -> Bool {
        command.requiresConfirmation || detectDangerousOperation(command) != nil
    }

    // MARK: - Action Type Validation

    func isValidActionType(_ action: CommandAction) -> Bool {
        switch action.type {
        case .appIntent, .appleScript, .shell:
            return true
        }
    }

    // MARK: - Payload Validation

    func validatePayload(_ action: CommandAction) -> String? {
        let payload = action.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return "Payload cannot be empty"
        }

        switch action.type {
        case .appIntent:
            return validateAppIntentPayload(payload)
        case .appleScript:
            return validateAppleScriptPayload(payload)
        case .shell:
            return validateShellPayload(payload)
        }
    }

    private func validateAppIntentPayload(_ payload: String) -> String? {
        let components = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard let intentName = components.first, !intentName.isEmpty else {
            return "App Intent name cannot be empty"
        }
        return nil
    }

    private func validateAppleScriptPayload(_ payload: String) -> String? {
        if !isValidAppleScript(payload) {
            return "Invalid AppleScript syntax"
        }
        return nil
    }

    private func validateShellPayload(_ payload: String) -> String? {
        let parsed: ShellPayload
        do {
            parsed = try ShellPayload.resolve(payload)
        } catch {
            return error.localizedDescription
        }
        if !isAllowedShellCommand(parsed.command) {
            return "Command '\(parsed.command)' is not allowed for safety reasons"
        }
        return nil
    }

    // MARK: - Dangerous Operation Detection

    private struct DangerDetection {
        let message: String
        let severity: ConfirmationSeverity
    }

    private func detectDangerousOperation(_ command: Command) -> DangerDetection? {
        let dangerousPatterns: [(String, ConfirmationSeverity, String)] = [
            ("do shell script", .high, "This will run a shell command from AppleScript"),
            ("rm -rf", .high, "This will permanently delete files/folders"),
            ("sudo", .high, "This will run with administrator privileges"),
            ("dd if=", .high, "This can overwrite disk data"),
            ("diskutil erase", .high, "This will erase disk"),
            ("format disk", .high, "This will erase data"),
            ("mkfs", .high, "This will create a filesystem, erasing existing data"),

            ("rm ", .medium, "This will delete files"),
            ("kill -9", .medium, "This will force quit processes"),
            ("chmod 777", .medium, "This will make files world-writable"),
            ("chown", .medium, "This will change file ownership"),
            ("delete every", .medium, "Bulk deletion operation"),

            ("curl", .low, "This will make a network request"),
            ("wget", .low, "This will download from the internet"),
        ]

        for action in command.actions {
            let payloads = [action.payload] + [action.fallbackAction?.payload].compactMap { $0 }
            for payload in payloads {
                let text = payload.lowercased()

                for (pattern, severity, message) in dangerousPatterns {
                    if text.contains(pattern) {
                        return DangerDetection(
                            message: "\(message). Payload: \(payload)",
                            severity: severity
                        )
                    }
                }
            }
        }

        return nil
    }

    // MARK: - File Path Validation

    func validateFilePaths(_ command: String, args: [String]) -> String? {
        let requiresExistingPath: Set<String> = ["cat", "rm", "cp", "mv", "open", "cd"]
        guard requiresExistingPath.contains(command) else { return nil }

        if let firstArg = args.first,
           firstArg.hasPrefix("/") || firstArg.hasPrefix("~") {
            let expanded = NSString(string: firstArg).expandingTildeInPath
            if !fileManager.fileExists(atPath: expanded) {
                return "Path does not exist: \(firstArg)"
            }
        }
        return nil
    }

    // MARK: - AppleScript Syntax Validation

    func isValidAppleScript(_ script: String) -> Bool {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return false
        }
        scriptObject.compileAndReturnError(&error)
        return error == nil
    }

    // MARK: - Shell Command Allow/Deny

    func isAllowedShellCommand(_ command: String) -> Bool {
        let allowed: Set<String> = [
            "open", "mkdir", "touch", "cp", "mv", "ls", "cat", "echo",
            "git", "npm", "yarn", "brew", "python", "python3", "node", "swift",
            "pwd", "whoami", "date", "which", "defaults",
            "cd", "find", "grep", "wc", "sort", "head", "tail",
            "say", "pbcopy", "pbpaste", "osascript",
        ]

        let banned: Set<String> = [
            "sudo", "rm", "dd", "format", "diskutil",
            "chmod", "chown", "kill", "mkfs", "fdisk",
        ]

        return allowed.contains(command) && !banned.contains(command)
    }
}
