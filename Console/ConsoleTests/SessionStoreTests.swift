import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class SessionStoreTests: XCTestCase {

    /// Isolated so tests never touch the hosted app's real defaults; a
    /// crashed or interrupted run must not leak `/bin/echo` into Console.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionStoreTests-\(UUID().uuidString)")
        defaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
    }

    // MARK: - Fakes

    private final class FakeLauncher: SessionProcessLaunching {
        var launchCount = 0
        var lastExecutable: String?
        var lastArguments: [String]?
        var lastEnvironment: [String: String]?
        var errorToThrow: Error?
        var exitShellStartCount = 0
        var lastExitShellWorkingDirectory: String?
        var lastExitShellEnvironment: [String: String]?

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
        ) throws {
            launchCount += 1
            lastExecutable = executable
            lastArguments = arguments
            lastEnvironment = environment
            if let errorToThrow {
                throw errorToThrow
            }
        }

        func startExitShell(
            workingDirectory: String,
            environment: [String: String],
            terminalView: LocalProcessTerminalView
        ) {
            exitShellStartCount += 1
            lastExitShellWorkingDirectory = workingDirectory
            lastExitShellEnvironment = environment
        }
    }

    private final class FakeAssembler: ConsoleClaudePluginAssembling {
        var errorToThrow: Error? = ConsoleClaudePluginAssembler.AssemblyError.missingResource("synthetic-plugin")
        var materializeCount = 0

        func materialize(in baseDirectory: URL) throws -> URL {
            materializeCount += 1
            if let errorToThrow {
                throw errorToThrow
            }
            return try ConsoleClaudePluginAssembler().materialize(in: baseDirectory)
        }
    }

    private struct SyntheticLaunchError: LocalizedError {
        var errorDescription: String? { "Synthetic launcher failed." }
    }

    private func makeStore(
        assembler: (any ConsoleClaudePluginAssembling)? = nil
    ) -> (SessionStore, FakeLauncher) {
        let launcher = FakeLauncher()
        let store = SessionStore(
            launcher: launcher,
            locator: ClaudeExecutableLocator(defaults: defaults),
            pluginAssembler: assembler ?? ConsoleClaudePluginAssembler()
        )
        return (store, launcher)
    }

    private func tmpDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-tests-\(UUID().uuidString)")
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Creation

    func testCreateSessionGeneratesDistinctIDsAndLaunchesClaude() throws {
        let (store, launcher) = makeStore()
        let dir = tmpDirectory("Alpha")
        let id = try store.createSession(name: "Alpha", workingDirectory: dir)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, id)
        let session = store.session(withID: id)!
        XCTAssertNotEqual(session.id, session.claudeSessionID)
        XCTAssertEqual(session.activity, .starting)

        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(launcher.lastExecutable, "/bin/echo")
        let args = launcher.lastArguments ?? []
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--name"), "local display name is not passed to Claude")
        XCTAssertFalse(args.contains("Alpha"))
        XCTAssertTrue(args.contains("--plugin-dir"))
        XCTAssertEqual(
            args.filter { $0.hasPrefix("mcp__plugin_console-bridge_console__") }.count,
            3,
            "exactly the three Console MCP tools are preapproved"
        )
        XCTAssertFalse(args.contains("*"), "no MCP wildcard is allowed")
    }

    func testLaunchEnvironmentMatchesDrawerTerminalLayering() throws {
        let (store, launcher) = makeStore()
        let consoleID = try store.createSession(name: "Env", workingDirectory: tmpDirectory("Env"))
        let environment = try XCTUnwrap(launcher.lastEnvironment)

        // Drawer-equivalent terminal defaults are present.
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")

        // Bridge identity always wins and matches this session.
        XCTAssertEqual(environment["CONSOLE_TERM_BRIDGE_SESSION_ID"], consoleID.uuidString)
        XCTAssertFalse((environment["CONSOLE_TERM_BRIDGE_TOKEN"] ?? "").isEmpty)

        // The launcher receives the complete sanitized environment: capture
        // artifacts and stale bridge variables must already be gone.
        XCTAssertNil(environment["PWD"])
        XCTAssertNil(environment["OLDPWD"])
        XCTAssertNil(environment["SHLVL"])
        XCTAssertEqual(
            environment.keys.filter { $0 != "CONSOLE_TERM_BRIDGE_HELPER" && $0 != "CONSOLE_TERM_BRIDGE_SOCKET" && $0 != "CONSOLE_TERM_BRIDGE_SESSION_ID" && $0 != "CONSOLE_TERM_BRIDGE_TOKEN" && $0.hasPrefix("CONSOLE_TERM_BRIDGE_") },
            [],
            "stale bridge-prefixed keys are stripped"
        )
    }

    func testFailedLoginShellCaptureIsRetriedOnNextCreation() throws {
        let (store, launcher) = makeStore()
        let fixturePath = "/fixture/bin:/usr/bin"
        var attempts = 0
        store.loginShellEnvironmentCapture = {
            attempts += 1
            return attempts == 1 ? nil : ["PATH": fixturePath]
        }

        _ = try store.createSession(name: "First", workingDirectory: tmpDirectory("First"))
        let firstEnvironment = try XCTUnwrap(launcher.lastEnvironment)
        XCTAssertNotEqual(firstEnvironment["PATH"], fixturePath, "first capture failed; no shell layer yet")

        _ = try store.createSession(name: "Second", workingDirectory: tmpDirectory("Second"))
        let secondEnvironment = try XCTUnwrap(launcher.lastEnvironment)
        XCTAssertEqual(secondEnvironment["PATH"], fixturePath, "a failed capture is retried, not locked out")
    }

    func testDuplicateActiveNamesAreSuffixed() throws {
        let (store, _) = makeStore()
        _ = try store.createSession(name: "Work", workingDirectory: tmpDirectory("A"))
        _ = try store.createSession(name: "Work", workingDirectory: tmpDirectory("B"))

        XCTAssertEqual(store.sessions.map(\.name), ["Work", "Work 2"])
    }

    func testSuggestedNameDerivedFromFolderAndUniqued() throws {
        let (store, _) = makeStore()
        XCTAssertEqual(store.suggestedName(for: tmpDirectory("Fresh")), "Fresh")
        _ = try store.createSession(name: "Fresh", workingDirectory: tmpDirectory("F1"))
        XCTAssertEqual(store.suggestedName(for: tmpDirectory("Fresh")), "Fresh 2")
    }

    func testCreationWithoutClaudeThrowsActionableError() throws {
        defaults.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        let notFound = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [] },
            defaults: defaults
        )
        let store = SessionStore(launcher: FakeLauncher(), locator: notFound)

        XCTAssertNil(notFound.locate())

        do {
            _ = try store.createSession(name: "X", workingDirectory: tmpDirectory("X"))
            XCTFail("expected claudeNotFound")
        } catch let error as SessionCreationError {
            guard case .claudeNotFound = error else {
                XCTFail("wrong error \(error)")
                return
            }
            XCTAssertTrue(error.errorDescription?.contains("Settings") == true)
        }
    }

    // MARK: - Selection

    func testSelectionSwitchesWithoutTouchingProcesses() throws {
        let (store, launcher) = makeStore()
        let a = try store.createSession(name: "A", workingDirectory: tmpDirectory("A"))
        let b = try store.createSession(name: "B", workingDirectory: tmpDirectory("B"))

        XCTAssertEqual(store.selectedSessionID, b)
        store.select(sessionID: a)
        XCTAssertEqual(store.selectedSessionID, a)
        XCTAssertEqual(launcher.launchCount, 2, "switching never relaunches processes")

        let viewA = store.session(withID: a)!.terminalView
        store.select(sessionID: b)
        store.select(sessionID: a)
        XCTAssertTrue(viewA === store.selectedSession!.terminalView, "terminal views persist across switching")
    }

    // MARK: - Stopping / removal / retention

    func testStopIdleSessionExitsImmediatelyWhenNoProcess() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Idle", workingDirectory: tmpDirectory("Idle"))
        store.stopSession(id: id)
        XCTAssertEqual(store.session(withID: id)?.activity, .exited)
    }

    func testExitedSessionsRetainScrollbackUntilRemoved() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Done", workingDirectory: tmpDirectory("D"))
        store.stopSession(id: id)

        XCTAssertEqual(store.sessions.count, 1, "exited sessions stay in the list")
        XCTAssertNotNil(store.selectedSession)

        store.removeSession(id: id)
        XCTAssertEqual(store.sessions.count, 0, "explicit removal clears exited sessions")
    }

    func testTerminateIdleSessionClosesImmediatelyWhenNoProcess() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Idle", workingDirectory: tmpDirectory("Idle"))
        store.terminateSession(id: id)

        XCTAssertTrue(store.sessions.isEmpty, "terminated sessions close instead of lingering")
        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.session(withID: id))
    }

    func testTerminateAlreadyExitedSessionClosesIt() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Done", workingDirectory: tmpDirectory("D"))
        store.stopSession(id: id)
        XCTAssertEqual(store.sessions.count, 1)

        store.terminateSession(id: id)
        XCTAssertTrue(store.sessions.isEmpty, "terminating an exited session removes it")
    }

    func testProcessTerminatedAfterTerminateClosesSession() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Live", workingDirectory: tmpDirectory("L"))

        // Simulate the graceful-stop path: flag for close, then the process
        // delegate reports termination.
        store.terminateSession(id: id)
        store.handleProcessTerminated(sessionID: id)

        XCTAssertTrue(store.sessions.isEmpty, "process exit after terminate closes the session")
    }

    func testProcessTerminatedWithoutTerminateRetainsSession() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Live", workingDirectory: tmpDirectory("L"))
        store.handleProcessTerminated(sessionID: id)

        XCTAssertEqual(store.sessions.count, 1, "natural process exit keeps the exited row")
        XCTAssertEqual(store.session(withID: id)?.activity, .exited)
    }

    func testNaturalProcessExitStartsExitShellPrompt() throws {
        let (store, launcher) = makeStore()
        let dir = tmpDirectory("Prompt")
        let id = try store.createSession(name: "Live", workingDirectory: dir)
        store.handleProcessTerminated(sessionID: id)

        XCTAssertEqual(launcher.exitShellStartCount, 1, "a retained pane returns to a shell prompt after Claude exits")
        XCTAssertEqual(launcher.lastExitShellWorkingDirectory, dir.path)
        let environment = try XCTUnwrap(launcher.lastExitShellEnvironment)
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertFalse(
            environment.keys.contains { $0.hasPrefix("CONSOLE_TERM_BRIDGE_") },
            "the exit shell carries no bridge identity"
        )
    }

    func testTerminateThenProcessExitDoesNotStartExitShell() throws {
        let (store, launcher) = makeStore()
        let id = try store.createSession(name: "Live", workingDirectory: tmpDirectory("L"))

        store.terminateSession(id: id)
        store.handleProcessTerminated(sessionID: id)

        XCTAssertEqual(launcher.exitShellStartCount, 0, "user-terminated sessions close instead of respawning a shell")
    }

    func testExitShellRestartWhenPromptShellExits() throws {
        let (store, launcher) = makeStore()
        let id = try store.createSession(name: "Live", workingDirectory: tmpDirectory("L"))
        store.handleProcessTerminated(sessionID: id)
        store.handleProcessTerminated(sessionID: id)

        XCTAssertEqual(launcher.exitShellStartCount, 2, "an exited pane stays usable until explicitly closed")
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.session(withID: id)?.activity, .exited)
    }

    func testTerminateAllDoesNotStartExitShell() throws {
        let (store, launcher) = makeStore()
        _ = try store.createSession(name: "One", workingDirectory: tmpDirectory("One"))
        store.terminateAll()

        XCTAssertEqual(launcher.exitShellStartCount, 0, "app termination must not spawn shells")
    }

    func testRemoveRefusesNonExitedSessions() throws {
        let (store, _) = makeStore()
        let id = try store.createSession(name: "Live", workingDirectory: tmpDirectory("L"))
        store.removeSession(id: id)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testTerminateAllMarksEverythingExited() throws {
        let (store, _) = makeStore()
        _ = try store.createSession(name: "One", workingDirectory: tmpDirectory("One"))
        _ = try store.createSession(name: "Two", workingDirectory: tmpDirectory("Two"))
        store.terminateAll()
        XCTAssertTrue(store.sessions.allSatisfy { $0.activity == .exited })
        XCTAssertEqual(store.sessions.count, 2, "termination keeps rows visible until quit")
    }

    func testSourceDisplayNameNeverReachesChildProcessNameOrTerminal() throws {
        let (store, launcher) = makeStore()
        let sentinelKey = "SYN-99999"
        let sentinelTitle = "SENTINEL-TITLE-ZXCVBNM"
        let sentinelURL = URL(string: "https://sentinel.example.test/browse/SYN-99999")!
        let id = try store.createSession(request: SessionCreationRequest(
            purpose: .existingTicket,
            name: sentinelKey,
            workingDirectory: tmpDirectory("Repo"),
            source: .jira(key: sentinelKey, title: sentinelTitle, url: sentinelURL)
        ))

        let session = try XCTUnwrap(store.session(withID: id))
        XCTAssertEqual(session.name, sentinelKey)
        XCTAssertTrue(session.artifacts.contains { $0.label == sentinelKey })

        let argv = (launcher.lastArguments ?? []).joined(separator: " ")
        let env = (launcher.lastEnvironment ?? [:]).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let sends = store.debugTerminalSendBytes.map(\.utf8).joined(separator: "\n")
        for token in [sentinelKey, sentinelTitle, sentinelURL.absoluteString, "sentinel.example.test"] {
            XCTAssertFalse(argv.contains(token), "argv leaked \(token)")
            XCTAssertFalse(env.contains(token), "environment leaked \(token)")
            XCTAssertFalse(sends.contains(token), "terminal-send leaked \(token)")
        }
        XCTAssertFalse(argv.contains("--name"))
        XCTAssertTrue(store.debugTerminalSendBytes.isEmpty)
    }

    // MARK: - Optional instrumentation vs process creation

    func testPluginAssemblyFailureLaunchesUninstrumentedSession() throws {
        let assembler = FakeAssembler()
        let (store, launcher) = makeStore(assembler: assembler)
        let dir = tmpDirectory("Degraded")

        let id = try store.createSession(name: "Degraded", workingDirectory: dir)

        XCTAssertEqual(assembler.materializeCount, 1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, id)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(launcher.lastExecutable, "/bin/echo")

        let session = try XCTUnwrap(store.session(withID: id))
        XCTAssertEqual(session.activity, .starting)
        XCTAssertEqual(session.bridgeStatus, .unavailable)
        XCTAssertNotEqual(session.bridgeStatus, .active)
        XCTAssertEqual(
            session.instrumentationWarning,
            SessionCreationError.pluginAssemblyFailed.errorDescription
        )
        XCTAssertNil(store.debugSessionToken(id), "uninstrumented launches must not keep a bridge token")

        let args = launcher.lastArguments ?? []
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--plugin-dir"))
        XCTAssertFalse(args.contains("--allowedTools"))
        XCTAssertFalse(args.contains("--name"))
        XCTAssertFalse(args.contains("Degraded"))
        XCTAssertFalse(
            args.contains { $0.hasPrefix("mcp__plugin_console-bridge_console__") },
            "unusable MCP preapprovals must not be passed without a plugin"
        )

        let env = launcher.lastEnvironment ?? [:]
        XCTAssertNil(env["CONSOLE_TERM_BRIDGE_HELPER"])
        XCTAssertNil(env["CONSOLE_TERM_BRIDGE_SOCKET"])
        XCTAssertNil(env["CONSOLE_TERM_BRIDGE_SESSION_ID"])
        XCTAssertNil(env["CONSOLE_TERM_BRIDGE_TOKEN"])
        XCTAssertTrue(store.debugTerminalSendBytes.isEmpty)
        XCTAssertEqual(
            store.submit(prompt: "hello", to: id),
            .rejected(.sessionNotAcceptingInput),
            "never auto-submit into an unready terminal"
        )
    }

    func testPluginAssemblyFailureKeepsSourceMetadataOutOfChildProcess() throws {
        let (store, launcher) = makeStore(assembler: FakeAssembler())
        let sentinelKey = "SYN-99999"
        let sentinelTitle = "SENTINEL-TITLE-ZXCVBNM"
        let sentinelURL = URL(string: "https://sentinel.example.test/browse/SYN-99999")!
        let id = try store.createSession(request: SessionCreationRequest(
            purpose: .existingTicket,
            name: sentinelKey,
            workingDirectory: tmpDirectory("Repo"),
            source: .jira(key: sentinelKey, title: sentinelTitle, url: sentinelURL)
        ))

        let session = try XCTUnwrap(store.session(withID: id))
        XCTAssertEqual(session.name, sentinelKey)
        XCTAssertEqual(session.bridgeStatus, .unavailable)

        let argv = (launcher.lastArguments ?? []).joined(separator: " ")
        let env = (launcher.lastEnvironment ?? [:]).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let sends = store.debugTerminalSendBytes.map(\.utf8).joined(separator: "\n")
        for token in [sentinelKey, sentinelTitle, sentinelURL.absoluteString, "sentinel.example.test"] {
            XCTAssertFalse(argv.contains(token), "fallback argv leaked \(token)")
            XCTAssertFalse(env.contains(token), "fallback environment leaked \(token)")
            XCTAssertFalse(sends.contains(token), "fallback terminal-send leaked \(token)")
        }
        XCTAssertFalse(argv.contains("--name"))
        XCTAssertFalse(argv.contains("--plugin-dir"))
        XCTAssertTrue(store.debugTerminalSendBytes.isEmpty)
    }

    func testGenuineLaunchFailureRollsBackRowTokenAndSelection() throws {
        let (store, launcher) = makeStore()
        let first = try store.createSession(name: "Keep", workingDirectory: tmpDirectory("Keep"))
        XCTAssertEqual(store.selectedSessionID, first)
        let firstToken = store.debugSessionToken(first)

        launcher.errorToThrow = SyntheticLaunchError()
        XCTAssertThrowsError(
            try store.createSession(name: "Ghost", workingDirectory: tmpDirectory("Ghost"))
        ) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Synthetic launcher failed.")
        }

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, first)
        XCTAssertEqual(store.session(withID: first)?.name, "Keep")
        XCTAssertEqual(store.debugSessionToken(first), firstToken)
        XCTAssertNil(store.sessions.first { $0.name == "Ghost" })
        XCTAssertNotEqual(store.session(withID: first)?.bridgeStatus, .active)
    }

    func testRepeatedRetryAfterLaunchFailureCreatesAtMostOneNewSession() throws {
        let (store, launcher) = makeStore()
        _ = try store.createSession(name: "Existing", workingDirectory: tmpDirectory("Existing"))
        launcher.errorToThrow = SyntheticLaunchError()

        XCTAssertThrowsError(try store.createSession(name: "Retry", workingDirectory: tmpDirectory("R1")))
        XCTAssertThrowsError(try store.createSession(name: "Retry", workingDirectory: tmpDirectory("R2")))
        XCTAssertEqual(store.sessions.count, 1, "failed retries must not leave ghost rows")

        launcher.errorToThrow = nil
        let created = try store.createSession(name: "Retry", workingDirectory: tmpDirectory("R3"))

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, created)
        XCTAssertEqual(store.session(withID: created)?.name, "Retry")
    }

    func testUninstrumentedSessionDoesNotBecomeActiveWithoutValidatedEvent() throws {
        let (store, _) = makeStore(assembler: FakeAssembler())
        let id = try store.createSession(name: "Quiet", workingDirectory: tmpDirectory("Quiet"))

        store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: id.uuidString,
            token: "not-a-real-token",
            eventID: "evt-uninstrumented",
            kind: .lifecycle,
            lifecycleEvent: .sessionStarted
        ))

        XCTAssertEqual(store.session(withID: id)?.bridgeStatus, .unavailable)
        XCTAssertEqual(store.session(withID: id)?.activity, .starting)
    }
}
