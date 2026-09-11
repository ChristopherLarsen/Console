import XCTest
import SwiftTerm
@testable import Console

/// Real-PTY termination coverage: these tests spawn disposable shell scripts
/// as the session's "Claude" executable and assert OS process liveness, so a
/// termination defect cannot hide behind row or activity changes.
@MainActor
final class SessionTerminationProcessTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionTerminationProcessTests-\(UUID().uuidString)")
    }

    private func makeWorkspace(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-terminate-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return root
    }

    private func installFakeClaude(script: String, in root: URL) throws -> String {
        let executable = root.appendingPathComponent("fake claude")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defaults.set(executable.path, forKey: ClaudeExecutableLocator.settingsKey)
        return executable.path
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            launcher: ClaudeSessionLauncher(),
            locator: ClaudeExecutableLocator(defaults: defaults),
            restorationStore: nil
        )
    }

    private func recordedPIDs(_ log: URL) -> [pid_t] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        HeadlessSessionProcesses.identity(for: pid) != nil
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func cleanup(root: URL, terminal: LocalProcessTerminalView?, log: URL) {
        terminal?.processDelegate = nil
        for pid in recordedPIDs(log) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testTerminateStopsClaudeResumedUnderRetainedLoginShell() async throws {
        let root = makeWorkspace("resumed")
        let log = root.appendingPathComponent("pids.log")
        let executable = try installFakeClaude(
            script: """
            #!/bin/sh
            printf '%s\\n' "$$" >> '\(log.path)'
            case " $* " in
              *" --resume "*)
                while :; do /bin/sleep 1; done
                ;;
            esac
            """,
            in: root)

        let store = makeStore()
        let id = try store.createSession(name: "Resumed", workingDirectory: root)
        let terminal = try XCTUnwrap(store.session(withID: id)?.terminalView)
        defer { cleanup(root: root, terminal: terminal, log: log) }
        let initialShellPid = terminal.process?.shellPid

        let firstStarted = try await waitFor(recordedPIDs(log).count >= 1, timeout: 10)
        XCTAssertTrue(firstStarted, "the launched fake Claude never started")
        let firstPID = try XCTUnwrap(recordedPIDs(log).first)
        XCTAssertEqual(initialShellPid, firstPID,
                       "the PTY root must be the launched Claude process itself")

        let shellStarted = try await waitFor(
            terminal.process?.running == true && terminal.process?.shellPid != Int32(firstPID),
            timeout: 10)
        XCTAssertTrue(shellStarted,
                      "the retained login shell never replaced the exited Claude")
        let shellPID = try XCTUnwrap(terminal.process?.shellPid)
        terminal.send(txt: "'\(executable)' --resume stay\r")

        let resumedStarted = try await waitFor(recordedPIDs(log).count >= 2, timeout: 10)
        XCTAssertTrue(resumedStarted,
                      "Claude resumed from the login shell never started")
        let resumedPID = try XCTUnwrap(recordedPIDs(log).last)
        XCTAssertTrue(OwnedProcessTree.descendantIDs(of: shellPID).contains(resumedPID),
                      "the resumed Claude must run as a descendant of the retained shell")

        let token = try XCTUnwrap(store.debugSessionToken(id))
        store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: id.uuidString,
            token: token,
            eventID: UUID().uuidString,
            kind: .lifecycle,
            lifecycleEvent: .sessionStarted))
        XCTAssertEqual(store.session(withID: id)?.activity, .idle,
                       "the bridge sessionStarted event must revive the retained row")

        store.terminateSession(id: id)

        let stopped = try await waitFor(
            !isAlive(resumedPID) && !isAlive(shellPID) && store.session(withID: id) == nil,
            timeout: 15)
        XCTAssertTrue(stopped,
                      "terminate must stop the resumed Claude, the retained shell, and close the session")
    }

    private func spawnSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    func testSignalAttachedRefusesRecycledPIDIdentity() async throws {
        let sleeper = try spawnSleeper()
        defer {
            kill(sleeper.processIdentifier, SIGKILL)
            sleeper.waitUntilExit()
        }
        let realIdentity = try XCTUnwrap(HeadlessSessionProcesses.identity(for: sleeper.processIdentifier))
        let recycled = SessionProcessIdentity(
            pid: sleeper.processIdentifier,
            startedSeconds: realIdentity.startedSeconds &+ 10_000,
            startedMicroseconds: realIdentity.startedMicroseconds)

        HeadlessSessionProcesses.signalAttached([recycled], SIGTERM)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(HeadlessSessionProcesses.isAttachedAlive(realIdentity),
                      "a mismatched start time must never be signaled")
        HeadlessSessionProcesses.signalAttached([realIdentity], SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while HeadlessSessionProcesses.isAttachedAlive(realIdentity) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(HeadlessSessionProcesses.isAttachedAlive(realIdentity),
                       "the matching identity must be signaled")
    }

    func testSignalAttachedSignalsOnlyTheCapturedIdentity() async throws {
        let first = try spawnSleeper()
        let second = try spawnSleeper()
        defer {
            kill(first.processIdentifier, SIGKILL)
            kill(second.processIdentifier, SIGKILL)
            first.waitUntilExit()
            second.waitUntilExit()
        }
        let firstIdentity = try XCTUnwrap(HeadlessSessionProcesses.identity(for: first.processIdentifier))
        let secondIdentity = try XCTUnwrap(HeadlessSessionProcesses.identity(for: second.processIdentifier))

        HeadlessSessionProcesses.signalAttached([firstIdentity], SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while HeadlessSessionProcesses.isAttachedAlive(firstIdentity) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(HeadlessSessionProcesses.isAttachedAlive(firstIdentity))
        XCTAssertTrue(HeadlessSessionProcesses.isAttachedAlive(secondIdentity),
                      "an unrelated process must never be signaled")
    }

    private final class NoProcessLauncher: SessionProcessLaunching {
        func makeTerminalView() -> LocalProcessTerminalView {
            let view = ConsoleTerminalView()
            view.configureAppearance()
            return view
        }

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

    func testLateBridgeEventCannotResurrectClosedSession() throws {
        defaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
        let root = makeWorkspace("late")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(
            launcher: NoProcessLauncher(),
            locator: ClaudeExecutableLocator(defaults: defaults),
            restorationStore: nil
        )
        let id = try store.createSession(name: "Late", workingDirectory: root)

        store.terminateSession(id: id)
        XCTAssertNil(store.session(withID: id))
        XCTAssertNil(store.debugSessionToken(id), "a closed session must lose its bridge token")

        store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: id.uuidString,
            token: "stale-token",
            eventID: UUID().uuidString,
            kind: .lifecycle,
            lifecycleEvent: .sessionStarted))
        XCTAssertNil(store.session(withID: id),
                     "a late bridge event must not resurrect a closed session")
    }

    func testTerminateStopsDirectlyLaunchedClaudeAndClosesSession() async throws {
        let root = makeWorkspace("direct")
        let log = root.appendingPathComponent("pids.log")
        _ = try installFakeClaude(
            script: """
            #!/bin/sh
            printf '%s\\n' "$$" >> '\(log.path)'
            while :; do /bin/sleep 1; done
            """,
            in: root)

        let store = makeStore()
        let id = try store.createSession(name: "Direct", workingDirectory: root)
        let terminal = try XCTUnwrap(store.session(withID: id)?.terminalView)
        defer { cleanup(root: root, terminal: terminal, log: log) }
        let initialShellPid = terminal.process?.shellPid

        let firstStarted = try await waitFor(recordedPIDs(log).count >= 1, timeout: 10)
        XCTAssertTrue(firstStarted)
        let rootPID = try XCTUnwrap(recordedPIDs(log).first)
        XCTAssertEqual(initialShellPid, rootPID,
                       "a fresh session's PTY root must be the Claude process itself")

        store.terminateSession(id: id)

        let stopped = try await waitFor(
            !isAlive(rootPID) && store.session(withID: id) == nil,
            timeout: 15)
        XCTAssertTrue(stopped,
                      "terminate must stop the directly launched Claude and close the session")
    }
}
