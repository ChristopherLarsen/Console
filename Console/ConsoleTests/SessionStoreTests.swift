import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class SessionStoreTests: XCTestCase {

    private var storedOverrideBefore: String?

    override func setUp() {
        super.setUp()
        storedOverrideBefore = UserDefaults.standard.string(forKey: ClaudeExecutableLocator.settingsKey)
        UserDefaults.standard.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
    }

    override func tearDown() {
        if let storedOverrideBefore {
            UserDefaults.standard.set(storedOverrideBefore, forKey: ClaudeExecutableLocator.settingsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        }
        super.tearDown()
    }

    // MARK: - Fakes

    private final class FakeLauncher: SessionProcessLaunching {
        var launchCount = 0
        var lastExecutable: String?
        var lastArguments: [String]?
        var lastEnvironment: [String: String]?

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
        }
    }

    private func makeStore() -> (SessionStore, FakeLauncher) {
        let launcher = FakeLauncher()
        let store = SessionStore(launcher: launcher)
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
        XCTAssertTrue(args.contains("--name"))
        XCTAssertTrue(args.contains("Alpha"))
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
        UserDefaults.standard.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        let notFound = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [] }
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
}
