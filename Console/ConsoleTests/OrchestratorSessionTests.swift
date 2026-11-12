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

    func testDirectiveIsHeldUntilTargetCanTakeInput() throws {
        let store = makeStore()
        let directory = tmpDirectory("held")
        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general, name: "Worker", workingDirectory: directory
        ))
        let worker = try XCTUnwrap(store.session(withID: workerID))
        XCTAssertFalse(SessionStore.canTakeDirective(worker))
        XCTAssertEqual(store.deliverDirective("do it", to: workerID, relayTo: nil), .held)
        XCTAssertEqual(store.deliverDirective("do it", to: workerID, relayTo: nil), .duplicate)
        XCTAssertEqual(store.pendingDirectiveCount(for: workerID), 1)
    }

    func testRecentTypingCountsAsComposing() throws {
        let store = makeStore()
        let directory = tmpDirectory("typing")
        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general, name: "Worker", workingDirectory: directory
        ))
        XCTAssertFalse(store.userMayBeTyping(in: workerID))
        store.noteUserInput(sessionID: workerID)
        XCTAssertTrue(store.userMayBeTyping(in: workerID))
        XCTAssertFalse(store.userMayBeTyping(
            in: workerID, now: Date().addingTimeInterval(SessionStore.typingQuietSeconds + 1)
        ))
    }

    func testRelayNoteNamesTargetOutcomeAndSummary() throws {
        let store = makeStore()
        let directory = tmpDirectory("relay")
        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general, name: "Worker", workingDirectory: directory
        ))
        let worker = try XCTUnwrap(store.session(withID: workerID))
        let note = SessionStore.relayNote(target: worker, outcome: "finished")
        XCTAssertTrue(note.hasPrefix("Console relay: session \"Worker\""))
        XCTAssertTrue(note.contains(workerID.uuidString))
        XCTAssertTrue(note.contains("finished your directive"))
        XCTAssertFalse(note.contains("\n"))
    }

    func testRelayNoteQuotesLastReplyOnOneLine() throws {
        let store = makeStore()
        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general, name: "Worker", workingDirectory: tmpDirectory("reply")
        ))
        let worker = try XCTUnwrap(store.session(withID: workerID))
        let note = SessionStore.relayNote(target: worker, outcome: "finished", lastReply: "Done.\nNMA-1 fixed")
        XCTAssertTrue(note.contains("Last reply: Done. NMA-1 fixed"))
        XCTAssertFalse(note.contains("\n"))
    }

    func testTranscriptTailReturnsLastAssistantTextInOrder() {
        let jsonl = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"second"}]}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(TranscriptTail.lastAssistantMessages(inJSONL: jsonl, count: 2), ["first", "second"])
        XCTAssertEqual(TranscriptTail.lastAssistantMessages(inJSONL: jsonl, count: 1), ["second"])
    }

    func testCancelDropsOnlyRequestersHeldDirectives() throws {
        let store = makeStore()
        let directory = tmpDirectory("cancel")
        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general, name: "Worker", workingDirectory: directory
        ))
        let orchestratorID = UUID()
        store.deliverDirective("a", to: workerID, relayTo: orchestratorID)
        store.deliverDirective("b", to: workerID, relayTo: nil)
        XCTAssertEqual(store.cancelHeldDirectives(for: workerID, from: orchestratorID), 1)
        XCTAssertEqual(store.pendingDirectiveCount(for: workerID), 1)
    }

    func testRunPromptIsOneLinePointingAtBrief() {
        let prompt = OrchestratorScanBrief.runPrompt(briefPath: "/tmp/x/orchestrator-brief.md")
        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertTrue(prompt.contains("/tmp/x/orchestrator-brief.md"))
        XCTAssertTrue(prompt.contains("orchestrator-run"))
    }

    func testVersionComparisonHelpers() {
        XCTAssertEqual(ClaudeExecutableLocator.parseVersion(from: "claude 2.1.224 (Claude Code)"), "2.1.224")
        XCTAssertTrue(ClaudeExecutableLocator.isVersion("2.1.100", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.1.224", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.2.0", lessThan: "2.1.224"))
    }
}
