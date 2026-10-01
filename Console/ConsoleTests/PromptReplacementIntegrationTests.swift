import XCTest
import SwiftTerm
@testable import Console

/// Verifies the shared replacement-and-submit path against a live PTY: the
/// Single-line drafts are replaced in the shell's actual editor, not just
/// erased from the screen. Multiline continuation is a documented limitation.
@MainActor
final class PromptReplacementIntegrationTests: XCTestCase {

    private final class ShellSessionLauncher: SessionProcessLaunching {
        func makeTerminalView() -> LocalProcessTerminalView { ConsoleTerminalView() }
        func launch(
            executable: String,
            arguments: [String],
            environment: [String: String],
            workingDirectory: String,
            terminalView: LocalProcessTerminalView
        ) throws {}
        func startExitShell(
            workingDirectory: String,
            environment: [String: String],
            terminalView: LocalProcessTerminalView
        ) {}
    }

    private var defaults: UserDefaults!
    private var roots: [URL] = []
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PromptReplacementIntegrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
    }

    // MARK: - Harness

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeStoreWithLiveShell() throws -> (SessionStore, UUID, LocalProcessTerminalView, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-replacement-\(UUID().uuidString)")
        let zdotdir = root.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        roots.append(root)
        // Empty ZDOTDIR keeps zsh's default emacs bindings (^U = kill-whole-line).
        try "PS1='$ '\n".write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            launcher: ShellSessionLauncher(),
            locator: ClaudeExecutableLocator(defaults: defaults)
        )
        store.loginShellEnvironmentCapture = { nil }
        let sessionID = try store.createSession(name: "Live", workingDirectory: root)

        guard let session = store.session(withID: sessionID) else {
            XCTFail("session was not created")
            return (store, sessionID, ConsoleTerminalView(), root)
        }
        let terminal = session.terminalView
        let environment = [
            "TERM": "xterm-256color",
            "HOME": root.path,
            "ZDOTDIR": zdotdir.path,
            "PATH": "/usr/bin:/bin",
        ].map { "\($0.key)=\($0.value)" }.sorted()
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login", "-i"],
            environment: environment,
            execName: "zsh",
            currentDirectory: root.path
        )
        guard let pid = terminal.process?.shellPid, pid > 0 else {
            XCTFail("zsh did not start in the session's terminal view")
            return (store, sessionID, terminal, root)
        }
        return (store, sessionID, terminal, root)
    }

    /// The full text of the terminal's buffer, used instead of the raw output
    /// stream: the stream still contains erased input echoes, while the
    /// buffer reflects what the line editor actually left on screen.
    private func screenText(_ terminal: LocalProcessTerminalView) -> String {
        let term = terminal.getTerminal()
        var lines: [String] = []
        for row in 0..<500 {
            guard let line = term.bufferLine(atRow: row) else { break }
            lines.append(line.translateToString(trimRight: true))
        }
        return lines.joined(separator: "\n")
    }

    private func waitForScreen(
        _ terminal: LocalProcessTerminalView,
        toContain substring: String,
        timeout: TimeInterval = 10
    ) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = screenText(terminal)
        while !text.contains(substring) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            text = screenText(terminal)
        }
        return text
    }

    private func waitForOutput(_ root: URL) async throws -> String {
        let output = root.appendingPathComponent("result")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOf: output, encoding: .utf8), !text.isEmpty {
                return text
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Command never wrote its result")
        return ""
    }

    /// Opt-in end-to-end check against Claude's actual paste sanitization and
    /// submission handler, using SwiftTerm's PTY writes rather than a mock.
    func testLiveClaudeQuickCommandSubmitsWithoutInvisibleCharacterConfirmation() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CONSOLE_LIVE_CLAUDE"] else {
            throw XCTSkip("Set TEST_RUNNER_CONSOLE_LIVE_CLAUDE to the Claude executable")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let store = SessionStore(launcher: ShellSessionLauncher(), locator: ClaudeExecutableLocator(defaults: defaults))
        store.loginShellEnvironmentCapture = { nil }
        let sessionID = try store.createSession(name: "Claude input test", workingDirectory: root)
        let terminal = try XCTUnwrap(store.session(withID: sessionID)?.terminalView)
        defer { terminal.terminate() }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        terminal.startProcess(
            executable: executable,
            args: ["--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                   "--settings", "{\"disableAllHooks\":true}", "--permission-mode", "plan",
                   "--system-prompt", "This is a terminal input test. Reply only with QUICK_SUBMIT_OK. Do not perform any actions."],
            environment: environment.map { "\($0.key)=\($0.value)" }.sorted(),
            execName: "claude", currentDirectory: root.path
        )
        let ready = await waitForScreen(terminal, toContain: "plan mode on", timeout: 30)
        XCTAssertTrue(ready.contains("plan mode on"), "Claude did not reach its input prompt")
        guard ready.contains("plan mode on") else { return }
        XCTAssertEqual(store.sendSlashCommand(
            "Did the author post new comments or commits? If so, let's re-review the MR.", to: sessionID
        ), .submitted)
        let result = await waitForScreen(terminal, toContain: "QUICK_SUBMIT_OK", timeout: 60)
        XCTAssertFalse(result.contains("invisible characters"), "Clear-line controls were pasted as text")
        XCTAssertTrue(result.contains("QUICK_SUBMIT_OK"), "Claude did not submit and answer the command")
    }

    // MARK: - Cursor in the middle of a single-line draft

    func testReplacementClearsDraftWithCursorInMiddleBeforeSubmitting() async throws {
        let (store, sessionID, terminal, root) = try makeStoreWithLiveShell()
        defer { terminal.terminate() }

        let settled = await waitForScreen(terminal, toContain: "$ ")
        XCTAssertTrue(settled.contains("$ "), "zsh never showed a prompt")

        // A draft that would run if the Return went through uncleared, then
        // park the cursor in the middle of it.
        terminal.send(txt: "printf 'DRAFT_RAN\\n'")
        let left = Array(repeating: "\u{1B}[D", count: 4).joined()
        terminal.send(txt: left)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.sendSlashCommand("printf 'QUICK_OK\\n' > result", to: sessionID), .submitted)
        let output = try await waitForOutput(root)
        XCTAssertEqual(output, "QUICK_OK\n")
    }

    // MARK: - Multiline draft

    func testReplacementDoesNotClearEarlierMultilineContinuation() async throws {
        let (store, sessionID, terminal, root) = try makeStoreWithLiveShell()
        defer { terminal.terminate() }

        let settled = await waitForScreen(terminal, toContain: "$ ")
        XCTAssertTrue(settled.contains("$ "), "zsh never showed a prompt")

        // Two pending lines: a backslash continuation puts the buffer in a
        // PS2 continuation, so a lone line-kill would leave the first line
        // behind and Return would execute it.
        terminal.send(txt: "printf 'MULTI_RAN\\n' \\\r")
        terminal.send(txt: "second line")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.sendSlashCommand("printf 'QUICK_OK\\n' > result", to: sessionID), .submitted)
        let output = try await waitForOutput(root)
        XCTAssertEqual(output, "MULTI_RAN\n", "Earlier continuation lines remain; clear them manually first")
    }

    // MARK: - Shared path ordering against a live shell

    func testSendSlashCommandEmitsOrderedBytesToLiveShell() async throws {
        let (store, sessionID, terminal, root) = try makeStoreWithLiveShell()
        defer { terminal.terminate() }
        store.queuedCommandSpacing = 0

        _ = await waitForScreen(terminal, toContain: "$ ")
        XCTAssertEqual(store.sendSlashCommand("printf 'ORDER_OK\\n' > result", to: sessionID), .submitted)

        let sent = store.debugTerminalSendBytes
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.first?.sessionID, sessionID)
        XCTAssertEqual(sent.first?.utf8, "\u{15}\u{0B}")
        XCTAssertEqual(sent[1].utf8, "\u{1B}[200~printf 'ORDER_OK\\n' > result\u{1B}[201~")
        XCTAssertEqual(sent.last?.utf8, "\r", "the Return is written separately so it submits")

        let output = try await waitForOutput(root)
        XCTAssertEqual(output, "ORDER_OK\n")
    }
}
