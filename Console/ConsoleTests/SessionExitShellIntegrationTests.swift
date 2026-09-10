import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class SessionExitShellIntegrationTests: XCTestCase {
    private final class RecordingTerminal: LocalProcessTerminalView {
        var output = ""
        var didExit: (() -> Void)?

        override func dataReceived(slice: ArraySlice<UInt8>) {
            output += String(decoding: slice, as: UTF8.self)
            super.dataReceived(slice: slice)
        }

        override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            didExit?()
        }
    }

    func testExitedChildReturnsToWorkingInteractiveShell() async throws {
        let terminal = RecordingTerminal(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let launcher = ClaudeSessionLauncher()
        let directory = FileManager.default.temporaryDirectory.path
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        var replacementStarted = false
        let originalProcess = terminal.process
        terminal.didExit = {
            DispatchQueue.main.async {
                launcher.startExitShell(workingDirectory: directory,
                                        environment: environment, terminalView: terminal)
                replacementStarted = true
            }
        }
        defer {
            terminal.didExit = nil
            terminal.terminate()
        }
        try launcher.launch(executable: "/bin/sh", arguments: ["-c", "printf 'child finished\\n'"],
                            environment: environment, workingDirectory: directory, terminalView: terminal)
        let deadline = Date().addingTimeInterval(10)
        while !replacementStarted && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(replacementStarted)
        XCTAssertFalse(terminal.process === originalProcess, "The shell must own fresh PTY state")
        terminal.didExit = nil
        // Output differs from the command's echoed input, proving execution.
        terminal.send(txt: "printf 'SHELL_%s_OK\\n' READY\r")
        while !terminal.output.contains("SHELL_READY_OK") && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(terminal.output.contains("SHELL_READY_OK"), "Interactive shell did not execute input")
        XCTAssertTrue(terminal.process.running)
    }

    func testResumeCommandLoadsPluginAndRetainsBridgeInLoginShell() async throws {
        try await assertResumeCommand(originalZdotdir: true)
    }

    func testResumeCommandWithDefaultUserStartupDirectory() async throws {
        try await assertResumeCommand(originalZdotdir: false)
    }

    private func assertResumeCommand(originalZdotdir: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume shell '\(UUID())")
        let userRoot = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Prove that normal user startup still runs, including an existing alias.
        try "export RESUME_STARTUP_OK=yes\nalias claude=false\n".write(
            to: userRoot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let fakeClaude = root.appendingPathComponent("fake claude")
        try #"""
        #!/bin/sh
        printf 'RESUME_ARGS:<%s><%s><%s><%s>\n' "$1" "$2" "$3" "$4"
        printf 'RESUME_ENV:<%s><%s><%s>\n' "$CONSOLE_TERM_BRIDGE_SESSION_ID" "$CONSOLE_TERM_BRIDGE_TOKEN" "$RESUME_STARTUP_OK"
        """#.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path)
        let plugin = root.appendingPathComponent("plugin ' directory").path
        var base = [
            "HOME": userRoot.path, "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color", "CONSOLE_TERM_BRIDGE_SESSION_ID": "test-session",
            "CONSOLE_TERM_BRIDGE_TOKEN": "test-token",
        ]
        if originalZdotdir { base["ZDOTDIR"] = userRoot.path }
        let environment = try SessionExitShellBootstrap.environment(
            base, root: root.appendingPathComponent("bootstrap"), executable: fakeClaude.path, pluginDirectory: plugin)
        let terminal = RecordingTerminal(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        defer { terminal.terminate() }
        ClaudeSessionLauncher().startExitShell(
            workingDirectory: root.path, environment: environment, terminalView: terminal)
        terminal.send(txt: "claude --resume 'conversation id'\r")
        let deadline = Date().addingTimeInterval(10)
        while !terminal.output.contains("RESUME_ENV:<test-session><test-token><yes>") && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(terminal.output.contains("RESUME_ARGS:<--plugin-dir><\(plugin)><--resume><conversation id>"))
        XCTAssertTrue(terminal.output.contains("RESUME_ENV:<test-session><test-token><yes>"))
        XCTAssertTrue(terminal.process.running)
    }
}
