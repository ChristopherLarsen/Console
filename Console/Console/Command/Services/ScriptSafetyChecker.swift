import Foundation

enum ScriptSafetyChecker {
    enum RiskLevel: Comparable {
        case safe
        case caution
        case dangerous
    }

    struct Warning: Identifiable {
        let id = UUID()
        let level: RiskLevel
        let message: String
    }

    static func analyze(actions: [CommandAction]) -> [Warning] {
        var warnings: [Warning] = []
        for action in actions {
            warnings.append(contentsOf: analyzeAction(action))
        }
        return warnings.sorted { $0.level > $1.level }
    }

    private static func analyzeAction(_ action: CommandAction) -> [Warning] {
        guard action.type == .appleScript || action.type == .shell else { return [] }

        let script = action.payload.lowercased()
        var warnings: [Warning] = []

        let dangerousPatterns: [(pattern: String, message: String)] = [
            ("do shell script", "Executes a shell command which can modify system files"),
            ("rm -rf", "Recursively deletes files and directories"),
            ("rm -r", "Recursively deletes files and directories"),
            ("delete every", "Bulk deletion operation detected"),
            ("delete (every", "Bulk deletion operation detected"),
            ("format disk", "Disk format operation detected"),
            ("diskutil erase", "Disk erase operation detected"),
            ("sudo", "Elevated privilege command detected"),
            ("chmod", "File permission change detected"),
            ("chown", "File ownership change detected"),
            ("mkfs", "Filesystem creation detected"),
        ]

        let cautionPatterns: [(pattern: String, message: String)] = [
            ("delete", "Deletion operation detected"),
            ("trash", "Move to trash operation detected"),
            ("move", "File move operation detected"),
            ("system events", "Interacts with System Events"),
            ("system preferences", "Modifies System Preferences"),
            ("keychain", "Accesses Keychain data"),
            ("password", "Involves password handling"),
            ("empty trash", "Empties Trash permanently"),
        ]

        for (pattern, message) in dangerousPatterns {
            if script.contains(pattern) {
                warnings.append(Warning(level: .dangerous, message: message))
            }
        }

        for (pattern, message) in cautionPatterns {
            if script.contains(pattern) {
                let alreadyCovered = warnings.contains { $0.message == message }
                if !alreadyCovered {
                    warnings.append(Warning(level: .caution, message: message))
                }
            }
        }

        return warnings
    }
}
