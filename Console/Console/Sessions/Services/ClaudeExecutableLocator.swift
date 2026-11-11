import Foundation

/// Resolves the `claude` executable for session launches.
///
/// Resolution order:
/// 1. Valid executable path stored in Console Settings.
/// 2. Common Claude installation paths.
/// 3. `command -v claude` through the user's login shell.
@MainActor
final class ClaudeExecutableLocator {
    static let settingsKey = "claudeExecutableOverride"

    private let fileManager: FileManager
    private let shellRunner: (String) -> String?
    private let candidateProvider: () -> [String]
    /// Injectable so hosted unit tests never write the app's real defaults
    /// (a leaked `/bin/echo` override here once silently broke all launches).
    private let defaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        shellRunner: @escaping (String) -> String? = { ClaudeExecutableLocator.defaultShellRunner(command: $0) },
        candidateProvider: @escaping () -> [String] = { ClaudeExecutableLocator.commonPaths() },
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.shellRunner = shellRunner
        self.candidateProvider = candidateProvider
        self.defaults = defaults
    }

    /// The persisted Settings override, if any. This is the only value Console
    /// persists for this feature.
    var storedOverride: String? {
        defaults.string(forKey: Self.settingsKey)
    }

    func storeOverride(_ path: String?) {
        if let path, !path.isEmpty {
            defaults.set(path, forKey: Self.settingsKey)
        } else {
            defaults.removeObject(forKey: Self.settingsKey)
        }
    }

    func isValidExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }

    /// Resolves a usable claude executable, or nil when none can be found.
    func locate() -> String? {
        if let override = storedOverride, isValidExecutable(override) {
            return override
        }
        for candidate in candidateProvider() where isValidExecutable(candidate) {
            return candidate
        }
        if let shellPath = shellRunner("command -v claude"), isValidExecutable(shellPath) {
            return shellPath
        }
        return nil
    }

    /// Path shown in Settings: the detected executable, or the stale override
    /// so the user can see why creation fails.
    func displayPath() -> String? {
        locate() ?? storedOverride
    }

    /// Install locations scanned between the Settings override and the login
    /// shell lookup.
    nonisolated static func commonPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/bin/claude",
            "/usr/bin/claude",
            "/opt/local/bin/claude",
        ]
    }

    nonisolated static func defaultShellRunner(command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            let data = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (output?.isEmpty == false) ? output : nil
        } catch {
            return nil
        }
    }

    /// Best-effort Claude Code version string (e.g. `2.1.224`), or nil.
    func resolvedClaudeVersion() -> String? {
        guard let executable = locate() else { return nil }
        return Self.parseVersion(from: Self.defaultShellRunner(command: "\"\(executable)\" --version") ?? "")
    }

    /// Extracts a dotted numeric version from Claude's `--version` output.
    nonisolated static func parseVersion(from output: String) -> String? {
        let pattern = #"(\d+\.\d+\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range])
    }

    /// True when `lhs` is strictly older than `rhs` using dotted numeric parts.
    nonisolated static func isVersion(_ lhs: String, lessThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}
