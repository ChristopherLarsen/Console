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
        var bridgeEnvironment: [String: String] = [:]

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
            bridgeEnvironment = environment
        }

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

    private func makeStore(launcher: FakeLauncher? = nil) -> SessionStore {
        SessionStore(
            launcher: launcher ?? FakeLauncher(),
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

    private func startOrchestrator(in store: SessionStore, directory: URL) throws -> ConsoleSession {
        let id = try store.createSession(request: .init(
            purpose: .orchestrator, name: "Orchestrator", workingDirectory: directory
        ))
        return try XCTUnwrap(store.session(withID: id))
    }

    @discardableResult
    private func requestChild(in store: SessionStore, from requester: UUID,
                              name: String, purpose: SessionPurpose = .general,
                              prompt: String? = nil) throws -> String {
        let requestID = UUID().uuidString
        store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: requester.uuidString, token: try XCTUnwrap(store.debugSessionToken(requester)),
            eventID: UUID().uuidString, kind: .createSession, createPurpose: purpose.rawValue,
            createName: name, createInitialPrompt: prompt, requestID: requestID
        ))
        return requestID
    }

    @discardableResult
    private func requestDirective(in store: SessionStore, from lead: UUID, to target: UUID) throws -> String {
        let requestID = UUID().uuidString
        store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: lead.uuidString, token: try XCTUnwrap(store.debugSessionToken(lead)),
            eventID: UUID().uuidString, kind: .promptSession,
            targetSessionID: target.uuidString, promptText: "Follow-up", requestID: requestID
        ))
        return requestID
    }

    private func receive(_ event: BridgeProtocol.LifecycleEventKind, from id: UUID,
                         in store: SessionStore) throws {
        store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: id.uuidString, token: try XCTUnwrap(store.debugSessionToken(id)),
            eventID: UUID().uuidString, kind: .lifecycle, lifecycleEvent: event
        ))
    }

    private func readResult(_ requestID: String, directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(requestID).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func submittedText(_ text: String) -> String {
        String(decoding: PromptSubmissionEngine.replacementCommandText(text), as: UTF8.self)
    }

    func testCreatedChildrenAppearInOrderWithoutTakingFocusAndSnapshotLinksOnlyChildren() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let directory = tmpDirectory("children")
        let manualID = try store.createSession(name: "Manual", workingDirectory: directory)
        let lead = try startOrchestrator(in: store, directory: directory)
        for name in ["First", "Second", "Third"] {
            try requestChild(in: store, from: lead.id, name: name, prompt: "Work on \(name)")
        }
        let children = store.children(of: lead)
        XCTAssertEqual(children.map(\.name), ["First", "Second", "Third"])
        XCTAssertEqual(children.map(\.parentClaudeSessionID), Array(repeating: lead.claudeSessionID, count: 3))
        XCTAssertNil(store.session(withID: manualID)?.parentClaudeSessionID)
        XCTAssertEqual(store.selectedSessionID, lead.id)

        let path = try XCTUnwrap(launcher.bridgeEnvironment["CONSOLE_SESSIONS_SNAPSHOT"])
        func rows() throws -> [[String: Any]] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        }
        XCTAssertEqual(try rows().compactMap { $0["parent_id"] as? String },
                       Array(repeating: lead.id.uuidString, count: 3))
        store.handleProcessTerminated(sessionID: lead.id, startExitShell: false)
        XCTAssertEqual(store.children(of: lead).map(\.id), children.map(\.id))
        XCTAssertEqual(try rows().compactMap { $0["parent_id"] as? String }.count, 3)

        let replacement = try startOrchestrator(in: store, directory: directory)
        XCTAssertNil(store.session(withID: lead.id))
        XCTAssertTrue(store.children(of: replacement).isEmpty)
        XCTAssertTrue(children.allSatisfy { store.session(withID: $0.id)?.activity == .starting })
        XCTAssertTrue(try rows().compactMap { $0["parent_id"] as? String }.isEmpty)
    }

    func testChildLimitCountsLiveChildrenAndRejectsNonOrchestrator() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let directory = tmpDirectory("child-cap")
        let lead = try startOrchestrator(in: store, directory: directory)
        let manualID = try store.createSession(name: "Manual", workingDirectory: directory)
        let resultPath = try XCTUnwrap(launcher.bridgeEnvironment["CONSOLE_MCP_RESULTS_DIR"])
        let results = URL(fileURLWithPath: resultPath, isDirectory: true)
        let manualRequest = try requestChild(in: store, from: manualID, name: "Refused")
        XCTAssertFalse(try XCTUnwrap(readResult(manualRequest, directory: results)["ok"] as? Bool))
        XCTAssertEqual(store.sessions.count, 2)
        for number in 1...4 {
            try requestChild(in: store, from: lead.id, name: "Child \(number)")
        }
        let capRequest = try requestChild(in: store, from: lead.id, name: "Child 5")
        XCTAssertEqual(try readResult(capRequest, directory: results)["error"] as? String, "child limit reached (4)")
        XCTAssertEqual(store.children(of: lead).count, 4)

        let exited = try XCTUnwrap(store.children(of: lead).first)
        store.handleProcessTerminated(sessionID: exited.id, startExitShell: false)
        try requestChild(in: store, from: lead.id, name: "Child 5")
        XCTAssertEqual(store.children(of: lead).count, 5)
        XCTAssertEqual(store.children(of: lead).filter { $0.activity != .exited }.count, 4)
    }

    func testBlankChildRefusesInitialPromptAndDirectives() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("blank-child"))
        let results = URL(fileURLWithPath: try XCTUnwrap(launcher.bridgeEnvironment["CONSOLE_MCP_RESULTS_DIR"]))
        let invalid = try requestChild(in: store, from: lead.id, name: "Shell", purpose: .blank, prompt: "do work")
        XCTAssertEqual(try readResult(invalid, directory: results)["error"] as? String,
                       "blank sessions cannot take an initial_prompt")
        XCTAssertTrue(store.children(of: lead).isEmpty)

        try requestChild(in: store, from: lead.id, name: "Shell", purpose: .blank)
        let shell = try XCTUnwrap(store.children(of: lead).first)
        XCTAssertEqual(shell.purpose, .blank)
        let directive = try requestDirective(in: store, from: lead.id, to: shell.id)
        XCTAssertEqual(try readResult(directive, directory: results)["error"] as? String,
                       "blank sessions cannot be prompted")
        XCTAssertEqual(store.pendingDirectiveCount(for: shell.id), 0)
        XCTAssertFalse(store.debugTerminalSendBytes.contains { $0.sessionID == shell.id })
    }

    func testChildInitialPromptFollowsRenameAndOnlyFirstTurnRelays() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("child-relay"))
        try receive(.sessionStarted, from: lead.id, in: store)
        try receive(.promptSubmitted, from: lead.id, in: store)
        try requestChild(in: store, from: lead.id, name: "Worker", prompt: "First task")
        let child = try XCTUnwrap(store.children(of: lead).first)

        try receive(.sessionStarted, from: child.id, in: store)
        let writes = store.debugTerminalSendBytes.filter { $0.sessionID == child.id }.map(\.utf8)
        XCTAssertEqual(writes, [
            "\u{15}\u{0B}", submittedText("/rename Worker"), "\r",
            "\u{15}\u{0B}", submittedText("First task"), "\r",
        ])
        try receive(.promptSubmitted, from: child.id, in: store)
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.1))
        XCTAssertEqual(store.pendingDirectiveCount(for: lead.id), 1)

        try receive(.promptSubmitted, from: child.id, in: store)
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.1))
        XCTAssertEqual(store.pendingDirectiveCount(for: lead.id), 1)
        try receive(.turnCompleted, from: lead.id, in: store)
        let notes = store.debugTerminalSendBytes.filter { $0.sessionID == lead.id && $0.utf8.contains("Console relay:") }
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes.first?.utf8.contains("finished your directive") == true)
    }

    func testFollowUpDirectiveWaitsForChildStartupQueueAndFirstTurn() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0.01
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("startup-queue"))
        try requestChild(in: store, from: lead.id, name: "Worker", prompt: "First task")
        let child = try XCTUnwrap(store.children(of: lead).first)
        try requestDirective(in: store, from: lead.id, to: child.id)
        try receive(.sessionStarted, from: child.id, in: store)
        func writes() -> [String] {
            store.debugTerminalSendBytes.filter { $0.sessionID == child.id }.map(\.utf8)
        }
        XCTAssertEqual(writes(), ["\u{15}\u{0B}"])
        let deadline = ContinuousClock.now + .seconds(2)
        while writes().count < 6 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(writes().count, 6)
        XCTAssertEqual(store.pendingDirectiveCount(for: child.id), 1)

        try receive(.promptSubmitted, from: child.id, in: store)
        try receive(.turnCompleted, from: child.id, in: store)
        while writes().count < 9 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(writes().filter { $0.hasPrefix("\u{1B}[200~") },
                       [submittedText("/rename Worker"), submittedText("First task"), submittedText("Follow-up")])
    }

    func testManualSessionReceivesDirectiveAndRelaysWithoutBecomingAChild() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let directory = tmpDirectory("manual-directive")
        let lead = try startOrchestrator(in: store, directory: directory)
        try receive(.sessionStarted, from: lead.id, in: store)
        let manualID = try store.createSession(name: "Manual", workingDirectory: directory)
        try receive(.sessionStarted, from: manualID, in: store)
        try requestDirective(in: store, from: lead.id, to: manualID)
        XCTAssertTrue(store.debugTerminalSendBytes.contains {
            $0.sessionID == manualID && $0.utf8 == submittedText("Follow-up")
        })
        try receive(.promptSubmitted, from: manualID, in: store)
        try receive(.turnCompleted, from: manualID, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.1))
        XCTAssertEqual(store.debugTerminalSendBytes.filter {
            $0.sessionID == lead.id && $0.utf8.contains("Console relay: session \"Manual\"")
        }.count, 1)
        XCTAssertTrue(store.children(of: lead).isEmpty)
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
        XCTAssertTrue(brief.contains("approve the goal and plan"))
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
        XCTAssertTrue(note.hasSuffix("Update your plan. Continue approved steps; ask before anything off-plan."))
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
        XCTAssertTrue(prompt.contains("approve the goal and plan"))
    }

    func testVersionComparisonHelpers() {
        XCTAssertEqual(ClaudeExecutableLocator.parseVersion(from: "claude 2.1.224 (Claude Code)"), "2.1.224")
        XCTAssertTrue(ClaudeExecutableLocator.isVersion("2.1.100", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.1.224", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.2.0", lessThan: "2.1.224"))
    }
}
