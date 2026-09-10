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
}
