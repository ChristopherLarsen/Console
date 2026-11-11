import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class OrchestratorSessionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "OrchestratorSessionTests-\(UUID().uuidString)")
        defaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
    }

    private final class FakeLauncher: SessionProcessLaunching {
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

    private final class SucceedingAssembler: ConsoleClaudePluginAssembling {
        func materialize(in baseDirectory: URL) throws -> URL {
            try ConsoleClaudePluginAssembler().materialize(in: baseDirectory)
        }
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            launcher: FakeLauncher(),
            locator: ClaudeExecutableLocator(defaults: defaults),
            pluginAssembler: SucceedingAssembler(),
            restorationStore: nil
        )
    }

    private func tmpDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-tests-\(UUID().uuidString)")
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOrchestratorIsPinnedAboveLaterSessions() throws {
        let store = makeStore()
        let directory = tmpDirectory("pin")

        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general,
            name: "Worker",
            workingDirectory: directory
        ))
        let orchestratorID = try store.createSession(request: SessionCreationRequest(
            purpose: .orchestrator,
            name: "Orchestrator",
            workingDirectory: directory,
            revealsSession: false
        ))

        XCTAssertEqual(store.sessions.first?.id, orchestratorID)
        XCTAssertEqual(store.sessions.map(\.id), [orchestratorID, workerID])
    }

    func testTerminateSessionClosesOrchestrator() throws {
        let store = makeStore()
        let directory = tmpDirectory("terminate")

        let orchestratorID = try store.createSession(request: SessionCreationRequest(
            purpose: .orchestrator,
            name: "Orchestrator",
            workingDirectory: directory,
            revealsSession: false
        ))
        store.terminateSession(id: orchestratorID)
        XCTAssertNil(store.session(withID: orchestratorID))
    }

    func testRemoveSessionDropsExitedOrchestrator() throws {
        let store = makeStore()
        let directory = tmpDirectory("remove-orchestrator")
        let orchestratorID = try store.createSession(request: SessionCreationRequest(
            purpose: .orchestrator,
            name: "Orchestrator 2",
            workingDirectory: directory,
            revealsSession: false
        ))
        store.handleProcessTerminated(sessionID: orchestratorID, startExitShell: false)
        XCTAssertEqual(store.session(withID: orchestratorID)?.activity, .exited)
        store.removeSession(id: orchestratorID)
        XCTAssertNil(store.session(withID: orchestratorID))
    }

    func testUserSelectablePurposesOmitOrchestrator() {
        XCTAssertFalse(SessionPurpose.userSelectableCases.contains(.orchestrator))
        XCTAssertEqual(SessionPurpose.orchestrator.displayName, "Orchestrator")
        XCTAssertEqual(SessionPurpose.orchestrator.defaultName(source: nil), "Orchestrator")
    }

    func testScanBriefIncludesSessionsAndDirectiveNote() throws {
        let store = makeStore()
        let directory = tmpDirectory("brief")
        _ = try store.createSession(request: SessionCreationRequest(
            purpose: .general,
            name: "Worker",
            workingDirectory: directory
        ))
        let brief = OrchestratorScanBrief.build(sessions: store.sessions, homeSnapshot: nil)
        XCTAssertTrue(brief.contains("prompt_console_session"))
        XCTAssertTrue(brief.contains("Worker"))
        XCTAssertTrue(brief.contains("Run the orchestrator-run skill"))
        XCTAssertFalse(brief.contains("Optional("))
    }

    func testScanBriefPrintsTicketStatusWithoutOptionalWrapper() {
        let ticket = JiraTicketSummary(
            key: "NMA-17",
            summary: "Active story",
            status: "In Progress",
            priority: nil,
            updatedText: nil,
            issueURL: URL(string: "https://jira.example.com/browse/NMA-17")!,
            sourceOrder: 0
        )
        let snapshot = HomeBoardSnapshot(jiraTickets: [ticket], jiraStatus: .current)
        let brief = OrchestratorScanBrief.build(sessions: [], homeSnapshot: snapshot)
        XCTAssertTrue(brief.contains("NMA-17 (In Progress)"))
        XCTAssertFalse(brief.contains("Optional("))
    }

    func testRunOrchestratorDebouncesWhileRunning() throws {
        let store = makeStore()
        let workspaces = SessionWorkspaceStore(
            defaults: UserDefaults(suiteName: "OrchestratorWS-\(UUID().uuidString)")!
        )
        let directory = tmpDirectory("run")
        workspaces.setDefaultFolderPath(directory.path)
        let coordinator = SessionLaunchCoordinator(store: store, workspaceStore: workspaces)

        coordinator.runOrchestrator()
        XCTAssertEqual(coordinator.orchestratorRunState, .running)
        let firstCount = store.sessions.count
        coordinator.runOrchestrator()
        XCTAssertEqual(store.sessions.count, firstCount)
        XCTAssertEqual(coordinator.orchestratorRunState, .running)
    }

    func testVersionComparisonHelpers() {
        XCTAssertEqual(ClaudeExecutableLocator.parseVersion(from: "claude 2.1.224 (Claude Code)"), "2.1.224")
        XCTAssertTrue(ClaudeExecutableLocator.isVersion("2.1.100", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.1.224", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.2.0", lessThan: "2.1.224"))
    }
}
