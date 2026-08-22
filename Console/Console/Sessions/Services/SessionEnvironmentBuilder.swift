import Foundation

/// Builds the child environment for session launches so a session's Claude
/// process sees the same world as the global bottom drawer terminal.
///
/// The drawer spawns `/bin/zsh --login` through SwiftTerm, so a process typed
/// into it inherits SwiftTerm's terminal identity (TERM/COLORTERM) layered
/// by the login shell's rc files (PATH, user exports). Sessions exec `claude`
/// directly — never through a shell — so this builder reproduces that result
/// without wrapping the child:
///
/// 1. Console's own environment (GUI launch context).
/// 2. A sanitized snapshot of the user's login-shell environment (the same
///    effect as `.zshrc` in the drawer).
/// 3. PTY-provided terminal identity (TERM/COLORTERM), which the snapshot
///    cannot know because it runs without a TTY.
/// 4. Bridge identity variables, which must always win.
enum SessionEnvironmentBuilder {

    /// Matches SwiftTerm's `Terminal.getEnvironmentVariables(termName:)`.
    static let terminalDefaults = [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "LANG": "en_US.UTF-8",
    ]

    /// Snapshot artifacts that describe the capture shell itself, not the
    /// user's environment; they would be stale or wrong for the child.
    private static let snapshotArtifacts: Set<String> = ["PWD", "OLDPWD", "_", "SHLVL"]

    /// Bridge variables are added last by the caller and can never be
    /// overridden by anything captured from the shell.
    private static let bridgePrefix = "CONSOLE_TERM_BRIDGE_"

    /// Pure merge used by session launches. `loginShellEnvironment` may be nil
    /// when the snapshot is unavailable; sessions then keep working with the
    /// base environment plus terminal defaults.
    static func childEnvironment(
        base: [String: String],
        loginShellEnvironment: [String: String]?,
        bridge: [String: String]
    ) -> [String: String] {
        var merged = sanitized(base)
        if let loginShellEnvironment {
            // The snapshot shell runs without a PTY, so it cannot know the
            // terminal identity the drawer's PTY provides; identity variables
            // are therefore forced below, after this layer.
            for (key, value) in sanitized(loginShellEnvironment) {
                merged[key] = value
            }
        }
        // The drawer's PTY always provides these, overriding whatever Console
        // itself inherited; they are not learned from the non-TTY snapshot.
        merged["TERM"] = terminalDefaults["TERM"]
        merged["COLORTERM"] = terminalDefaults["COLORTERM"]
        if merged["LANG"]?.isEmpty != false {
            merged["LANG"] = terminalDefaults["LANG"]
        }
        for (key, value) in bridge {
            merged[key] = value
        }
        return merged.filter { !$0.value.isEmpty }
    }

    /// Captures `$SHELL --login -c /usr/bin/env`, the same login-shell layering
    /// the drawer's `zsh --login` applies. Returns nil when the shell cannot be
    /// run or its output cannot be parsed; callers degrade gracefully.
    nonisolated static func captureLoginShellEnvironment(
        shellPath: String? = ProcessInfo.processInfo.environment["SHELL"],
        runner: (String, [String]) -> String? = defaultRunner
    ) -> [String: String]? {
        guard let shellPath, !shellPath.isEmpty else { return nil }
        guard let output = runner(shellPath, ["--login", "-c", "/usr/bin/env"]) else { return nil }

        var environment: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            if !key.isEmpty {
                environment[key] = value
            }
        }
        return environment.isEmpty ? nil : environment
    }

    private static func sanitized(_ source: [String: String]) -> [String: String] {
        source.filter { key, _ in
            !snapshotArtifacts.contains(key) && !key.hasPrefix(bridgePrefix)
        }
    }

    private nonisolated static func defaultRunner(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
