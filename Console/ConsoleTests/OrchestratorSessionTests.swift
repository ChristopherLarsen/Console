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
        var arguments: [String] = []
        var workingDirectory: String?

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
            self.arguments = arguments
            self.workingDirectory = workingDirectory
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

    private func makeStore(launcher: FakeLauncher? = nil, restorationStore: SessionRestorationStore? = nil) -> SessionStore {
        SessionStore(
            launcher: launcher ?? FakeLauncher(),
            locator: ClaudeExecutableLocator(defaults: defaults),
            pluginAssembler: SucceedingAssembler(),
            restorationStore: restorationStore
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

    func testChildInitialPromptFollowsRenameAndIdleWhileBuildingDoesNotFinishDirective() async throws {
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
        store.transcriptReply = { _, _ in "Build is resolving packages; waiting for it to finish." }
        try receive(.promptSubmitted, from: child.id, in: store)
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        XCTAssertEqual(store.pendingDirectiveCount(for: lead.id), 1)
        try receive(.turnCompleted, from: lead.id, in: store)
        let notes = relayNotes(for: lead.id, in: store)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("ended its turn"))
        XCTAssertTrue(notes[0].contains("Build is resolving packages"))
        XCTAssertFalse(notes[0].contains("finished your directive"))

        try receive(.promptSubmitted, from: lead.id, in: store)
        try receive(.promptSubmitted, from: child.id, in: store)
        try send(.completion, from: child.id, in: store) { envelope in
            envelope.completionOutcome = .completed
            envelope.completionSummary = "Build passed."
        }
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        try receive(.turnCompleted, from: lead.id, in: store)
        XCTAssertTrue(relayNotes(for: lead.id, in: store).last?.contains("finished your directive") == true)
        XCTAssertTrue(relayNotes(for: lead.id, in: store).last?.contains("Build passed.") == true)
    }

    private func relayNotes(for id: UUID, in store: SessionStore) -> [String] {
        store.debugTerminalSendBytes.filter { $0.sessionID == id && $0.utf8.contains("Console relay:") }.map(\.utf8)
    }

    @discardableResult
    private func send(_ kind: BridgeProtocol.MessageKind, from id: UUID, in store: SessionStore,
                      configure: (inout BridgeEnvelope) -> Void = { _ in }) throws -> String {
        let requestID = UUID().uuidString
        var envelope = BridgeEnvelope(sessionID: id.uuidString, token: try XCTUnwrap(store.debugSessionToken(id)),
                                      eventID: UUID().uuidString, kind: kind, requestID: requestID)
        configure(&envelope)
        store.debugReceiveEnvelope(envelope)
        return requestID
    }

    func testHookLinkedMergeRequestSurvivesAnotherSessionsLinkAndReachesDecisionCards() throws {
        let store = makeStore()
        let root = tmpDirectory("hook-mr")
        let mr = "https://gitlab.example.test/team/app/-/merge_requests/42"
        for purpose in [SessionPurpose.general, .existingTicket] {
            let worker = try store.createSession(request: SessionCreationRequest(
                purpose: purpose, name: "Worker \(purpose.rawValue)", workingDirectory: root))
            let other = try store.createSession(request: SessionCreationRequest(
                purpose: .general, name: "Other \(purpose.rawValue)", workingDirectory: root))
            store.debugReceiveEnvelope(BridgeEnvelope(
                sessionID: worker.uuidString, token: try XCTUnwrap(store.debugSessionToken(worker)),
                eventID: UUID().uuidString, kind: .artifact, artifactKind: .gitlabMergeRequest,
                artifactLabel: "MR !42", artifactURL: mr))
            try store.connectJiraIssue(sessionID: other, url: XCTUnwrap(URL(string: "https://jira.example.test/browse/PROJ-3")))
            let session = try XCTUnwrap(store.session(withID: worker))
            XCTAssertEqual(HomeCardLinks.mergeRequest(in: session)?.absoluteString, mr, "\(purpose)")
            let decision = OrchestratorPlan.Decision(id: 1, question: "Merge?", options: ["yes"], session: worker.uuidString)
            XCTAssertEqual(HomeCardLinks(sessions: store.sessions).links(for: decision, session: session)
                .mergeRequest?.absoluteString, mr, "\(purpose)")
        }
    }

    func testClosingAChildSendsNoSecondRelay() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("close-relay"))
        try receive(.sessionStarted, from: lead.id, in: store)
        try requestChild(in: store, from: lead.id, name: "Check", prompt: "Check it")
        let child = try XCTUnwrap(store.children(of: lead).first)
        try receive(.sessionStarted, from: child.id, in: store)
        try receive(.promptSubmitted, from: child.id, in: store)
        store.transcriptReply = { _, _ in "Neither is approved." }
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        let before = relayNotes(for: lead.id, in: store).count
        XCTAssertEqual(before, 1)
        try send(.closeSession, from: lead.id, in: store) { $0.targetSessionID = child.id.uuidString }
        store.handleProcessTerminated(sessionID: child.id, startExitShell: false)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        XCTAssertEqual(relayNotes(for: lead.id, in: store).count, before)
    }

    func testRelayNoteKeepsALongReply() throws {
        let store = makeStore()
        let workerID = try store.createSession(request: SessionCreationRequest(
            purpose: .general, name: "Worker", workingDirectory: tmpDirectory("long-reply")
        ))
        let worker = try XCTUnwrap(store.session(withID: workerID))
        let reply = String(repeating: "x", count: 2_300) + " END"
        XCTAssertTrue(SessionStore.relayNote(target: worker, outcome: "finished", lastReply: reply).contains(" END"))
    }

    func testScanBriefMarksAnUnreadReviewQueueAsUnknown() {
        let snapshot = HomeBoardSnapshot(jiraStatus: .current, reviewStatus: HomeSourceStatus(check: .pending))
        let brief = OrchestratorScanBrief.build(sessions: [], homeSnapshot: snapshot)
        XCTAssertTrue(brief.contains("Review queue — GitLab scan (LOADING, no data yet: unknown, NOT empty)"))
        XCTAssertFalse(brief.contains("Review queue — GitLab scan (LOADING, no data yet: unknown, NOT empty)\n- (none)"))
    }

    func testScanBriefCarriesItemFactsLiveStateAndChangesButNoPlanJSON() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(URL(string: "https://gitlab.example.com/g/app/-/merge_requests/4035"))
        let item = MergeRequestSummary(
            id: url, iidText: "4035", title: "Mugshot cache", projectDisplayName: "g/app",
            authorDisplayName: "Sam", isDraft: false, pipelineDisplayState: nil, reviewDisplayState: nil,
            updatedText: nil, mergeRequestURL: url, sourceOrder: 0, triageCategory: .needsReview,
            triageReason: "No reviewer has commented.", jiraIssueKey: "NMA-9001"
        )
        let ticket = JiraTicketSummary(
            key: "NMA-8979", summary: "Crash on launch", status: "Next Up", priority: nil, updatedText: nil,
            issueURL: try XCTUnwrap(URL(string: "https://jira.example.com/browse/NMA-8979")), sourceOrder: 0,
            issueType: "Bug", fixVersion: "17.3"
        )
        let snapshot = HomeBoardSnapshot(
            jiraTickets: [ticket], jiraStatus: .current, reviewItems: [item],
            reviewStatus: HomeSourceStatus(check: .current, lastSuccessfulExtraction: now.addingTimeInterval(-240))
        )
        let facts = MRLiveFacts(state: "opened", headSHA: "abcdef1234567890", approvedBy: ["alex"], approvedByMe: false,
                                myReviewerState: "unreviewed", myUnresolvedThreads: 1, fetchedAt: now.addingTimeInterval(-5))
        let plan = OrchestratorPlan(goal: "Clear the review queue", steps: [
            .init(id: "R1", ownerSession: nil, directive: "SECRET-DIRECTIVE", status: .completed),
        ])
        let brief = OrchestratorScanBrief.build(
            sessions: [], homeSnapshot: snapshot, plan: plan, liveFacts: [url: facts],
            changes: .init(since: now.addingTimeInterval(-600), lines: ["!4028 left the review queue"]), now: now
        )
        XCTAssertTrue(brief.contains("Goal: Clear the review queue"))
        XCTAssertTrue(brief.contains("Steps: 1 completed"))
        XCTAssertFalse(brief.contains("SECRET-DIRECTIVE"))
        XCTAssertTrue(brief.contains("NMA-8979 (Next Up) [Bug, fix 17.3]: Crash on launch"))
        XCTAssertTrue(brief.contains("GitLab scan (as of 4 min ago)"))
        XCTAssertTrue(brief.contains("!4035 \"Mugshot cache\" | by Sam | NMA-9001 | Needs review: No reviewer has commented."))
        XCTAssertTrue(brief.contains("head abcdef12, approved by alex (you have NOT approved), your reviewer state: unreviewed, your unresolved threads: 1"))
        XCTAssertTrue(brief.contains("Changed since your last run (10 min ago)\n- !4028 left the review queue"))
    }

    func testPlanUpdateReturnsOnlyTheRevisionAndDropsApproved() throws {
        let store = makeStore(launcher: FakeLauncher())
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("plan-echo"))
        let root = try XCTUnwrap(store.writeOrchestratorBrief("Scan")).deletingLastPathComponent()
        let id = UUID().uuidString
        try Data(#"{"revision":0,"approved":true,"goal":"G","steps":[],"decisions":[]}"#.utf8)
            .write(to: root.appendingPathComponent("plan-update-\(id).json"))
        try send(.updatePlan, from: lead.id, in: store) { $0.requestID = id; $0.planUpdateID = id }
        let result = try readResult(id, directory: root.appendingPathComponent("mcp-results"))
        XCTAssertEqual(result["output"] as? String, #"{"ok":true,"revision":1}"#)
        XCTAssertFalse(String(decoding: try store.loadOrchestratorPlan().json(), as: UTF8.self).contains("approved"))
    }

    func testAPIErrorAfterIdleRelaysFailureToOriginalOrchestrator() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("api-failure"))
        try receive(.sessionStarted, from: lead.id, in: store)
        try requestChild(in: store, from: lead.id, name: "Build", prompt: "Build app")
        let child = try XCTUnwrap(store.children(of: lead).first)
        try receive(.sessionStarted, from: child.id, in: store)
        try receive(.promptSubmitted, from: child.id, in: store)
        store.transcriptReply = { _, _ in "Still building." }
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        XCTAssertTrue(relayNotes(for: lead.id, in: store).last?.contains("ended its turn") == true)

        try receive(.promptSubmitted, from: child.id, in: store)
        store.transcriptReply = { _, _ in "API Error: Connection lost mid-response" }
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        XCTAssertEqual(store.session(withID: child.id)?.activity, .error)
        try receive(.turnCompleted, from: lead.id, in: store)
        let failure = try XCTUnwrap(relayNotes(for: lead.id, in: store).last)
        XCTAssertTrue(failure.contains("failed your directive"))
        XCTAssertTrue(failure.contains("Connection lost mid-response"))
    }

    func testHeldRelayReadsLateTranscriptFlushAtDelivery() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let root = tmpDirectory("transcripts")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        store.transcriptReply = { id, since in
            TranscriptTail.currentTurnReply(claudeSessionID: id, since: since, projectsRoot: root)
        }
        let lead = try startOrchestrator(in: store, directory: root)
        try receive(.sessionStarted, from: lead.id, in: store)
        try receive(.promptSubmitted, from: lead.id, in: store)
        try requestChild(in: store, from: lead.id, name: "Worker", prompt: "First task")
        let child = try XCTUnwrap(store.children(of: lead).first)
        try receive(.sessionStarted, from: child.id, in: store)
        try receive(.promptSubmitted, from: child.id, in: store)
        let url = project.appendingPathComponent(child.claudeSessionID.uuidString.lowercased() + ".jsonl")
        let old = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Previous turn"}]}}"#
        let prompt = #"{"type":"user","message":{"content":"First task"}}"#
        let new = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Latest result"}]}}"#
        try [old, prompt].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try receive(.turnCompleted, from: child.id, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        XCTAssertEqual(store.pendingDirectiveCount(for: lead.id), 1)
        try [old, prompt, new].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try receive(.turnCompleted, from: lead.id, in: store)
        let note = try XCTUnwrap(relayNotes(for: lead.id, in: store).last)
        XCTAssertTrue(note.contains("Latest result"))
        XCTAssertFalse(note.contains("Previous turn"))
    }

    func testReadOnlyChildLaunchesInWorkspaceWithModelAndLongBrief() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        store.queuedCommandSpacing = 0
        let workspace = tmpDirectory("workspace")
        let checkout = workspace.appendingPathComponent("Console")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
        let git = checkout.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
        try "ref: refs/heads/review-fixture\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        store.childWorkspaceRoots = { [workspace] }
        let lead = try startOrchestrator(in: store, directory: workspace)
        let root = URL(fileURLWithPath: try XCTUnwrap(launcher.bridgeEnvironment["CONSOLE_TERM_BRIDGE_SOCKET"])).deletingLastPathComponent()
        let id = UUID().uuidString
        let brief = String(repeating: "Review this code.\n", count: 400)
        try brief.write(to: root.appendingPathComponent("child-brief-\(id).md"), atomically: true, encoding: .utf8)
        try send(.createSession, from: lead.id, in: store) { envelope in
            envelope.requestID = id
            envelope.createPurpose = "general"
            envelope.createName = "Fable review"
            envelope.createModel = "fable"
            envelope.createCWD = checkout.path
            envelope.createToolProfile = "readOnlyPrep"
            envelope.createBriefID = id
        }
        let child = try XCTUnwrap(store.children(of: lead).first)
        XCTAssertEqual(launcher.workingDirectory, checkout.resolvingSymlinksInPath().path)
        XCTAssertTrue(launcher.arguments.contains("fable"))
        XCTAssertTrue(launcher.arguments.contains("--model"))
        XCTAssertTrue(launcher.arguments.contains("dontAsk"))
        XCTAssertFalse(launcher.arguments.contains("--dangerously-skip-permissions"))
        let bundle = root.appendingPathComponent("child-context-\(id)/brief.md")
        XCTAssertEqual(try String(contentsOf: bundle, encoding: .utf8), brief)
        try receive(.sessionStarted, from: child.id, in: store)
        XCTAssertTrue(store.debugTerminalSendBytes.contains { $0.sessionID == child.id && $0.utf8.contains(bundle.path) })
        let path = try XCTUnwrap(launcher.bridgeEnvironment["CONSOLE_SESSIONS_SNAPSHOT"])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == child.id.uuidString })
        XCTAssertEqual(row["tool_profile"] as? String, "readOnlyPrep")
        XCTAssertEqual(row["model"] as? String, "fable")
        XCTAssertEqual(row["git_branch"] as? String, "review-fixture")
        XCTAssertNotNil(row["state_since"])
    }

    func testPlanUpdateChecksRevisionAndPersistsBesideScanBrief() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("plan"))
        let brief = try XCTUnwrap(store.writeOrchestratorBrief("Scan"))
        let root = brief.deletingLastPathComponent()
        let results = root.appendingPathComponent("mcp-results")
        let requestID = UUID().uuidString
        let plan = OrchestratorPlan(goal: "Finish review", steps: [
            .init(id: "review", ownerSession: nil, directive: "Review the current diff.", status: .pending),
        ], decisions: [.init(id: 1, question: "Post the review?", options: ["yes", "hold"])])
        func replacePlan(id: String) throws {
            try plan.json().write(to: root.appendingPathComponent("plan-update-\(id).json"))
            try send(.updatePlan, from: lead.id, in: store) { envelope in
                envelope.requestID = id
                envelope.planUpdateID = id
            }
        }
        try replacePlan(id: requestID)
        XCTAssertEqual(try store.loadOrchestratorPlan().revision, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("orchestrator-plan.json").path))
        let staleID = UUID().uuidString
        try replacePlan(id: staleID)
        XCTAssertEqual(try readResult(staleID, directory: results)["ok"] as? Bool, false)
        let get = try send(.getPlan, from: lead.id, in: store)
        let output = try XCTUnwrap(readResult(get, directory: results)["output"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(OrchestratorPlan.self, from: Data(output.utf8)).decisions, plan.decisions)
    }

    func testIdlePromptEndsAnInterruptedTurnOnceAndIgnoresViewing() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        store.transcriptReply = { _, _ in nil }
        let root = tmpDirectory("interrupt")
        let lead = try startOrchestrator(in: store, directory: root)
        let worker = try store.createSession(name: "Interrupted", workingDirectory: root)
        try receive(.sessionStarted, from: lead.id, in: store)
        try receive(.sessionStarted, from: worker, in: store)
        try send(.watchSession, from: lead.id, in: store) { $0.targetSessionID = worker.uuidString }
        try receive(.promptSubmitted, from: worker, in: store)
        // Stop never fires after an interrupt; the idle prompt is the only signal.
        try receive(.idleObserved, from: worker, in: store)
        XCTAssertEqual(store.session(withID: worker)?.activity, .idle)
        try receive(.idleObserved, from: worker, in: store)
        store.acknowledgeCompletion(sessionID: worker)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        let notes = relayNotes(for: lead.id, in: store)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes.first?.contains("ended its turn") == true)
        XCTAssertFalse(notes.contains { $0.contains("changed attention") })
    }

    func testWatchAndRecheckSurviveRelaunch() async throws {
        let restoration = SessionRestorationStore(url: tmpDirectory("relaunch").appendingPathComponent("restore.json"))
        let root = tmpDirectory("relaunch-work")
        let first = makeStore(restorationStore: restoration)
        let lead = try startOrchestrator(in: first, directory: root)
        let workerID = try first.createSession(name: "Watched", workingDirectory: root)
        let worker = try XCTUnwrap(first.session(withID: workerID))
        try receive(.sessionStarted, from: lead.id, in: first)
        try receive(.sessionStarted, from: workerID, in: first)
        try send(.watchSession, from: lead.id, in: first) { $0.targetSessionID = workerID.uuidString }
        try send(.recheckIn, from: lead.id, in: first) { $0.recheckMinutes = 0.1 }

        let second = makeStore(restorationStore: restoration)
        second.queuedCommandSpacing = 0
        second.transcriptReply = { _, _ in nil }
        let newWorker = try second.resumeSession(from: SessionRestorationRecord(
            claudeSessionID: worker.claudeSessionID, name: worker.name, workingDirectory: root, purpose: .general))
        let newLead = try second.resumeSession(from: SessionRestorationRecord(
            claudeSessionID: lead.claudeSessionID, name: lead.name, workingDirectory: root, purpose: .orchestrator))
        XCTAssertNotEqual(newWorker, workerID)
        try receive(.sessionStarted, from: newWorker, in: second)
        try receive(.sessionStarted, from: newLead, in: second)
        try receive(.promptSubmitted, from: newWorker, in: second)
        try receive(.turnFailed, from: newWorker, in: second)
        let deadline = ContinuousClock.now + .seconds(10)
        while relayNotes(for: newLead, in: second).count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            try receive(.turnCompleted, from: newLead, in: second)
        }
        let notes = relayNotes(for: newLead, in: second)
        XCTAssertTrue(notes.contains { $0.contains("failed.") })
        XCTAssertTrue(notes.contains { $0.contains("scheduled recheck is due") })
    }

    func testDirectiveOriginRetiresWhenTurnLeavesNoWorkRunning() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        store.transcriptReply = { _, _ in "Done." }
        store.liveWorkProbe = { _ in false }
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("retire"))
        try receive(.sessionStarted, from: lead.id, in: store)
        try requestChild(in: store, from: lead.id, name: "Check", prompt: "Check it")
        let child = try XCTUnwrap(store.children(of: lead).first)
        try receive(.sessionStarted, from: child.id, in: store)
        for _ in 0..<2 {
            try receive(.promptSubmitted, from: child.id, in: store)
            try receive(.turnCompleted, from: child.id, in: store)
            try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
            try receive(.turnCompleted, from: lead.id, in: store)
        }
        XCTAssertEqual(relayNotes(for: lead.id, in: store).count, 1)
    }

    func testUnreadablePlanIsSetAsideAndReadOnlyHistoryResumeStaysReadOnly() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let directory = tmpDirectory("recover")
        let lead = try startOrchestrator(in: store, directory: directory)
        let root = try XCTUnwrap(store.writeOrchestratorBrief("Scan")).deletingLastPathComponent()
        try "not a plan".write(to: root.appendingPathComponent("orchestrator-plan.json"), atomically: true, encoding: .utf8)
        let get = try send(.getPlan, from: lead.id, in: store)
        let result = try readResult(get, directory: root.appendingPathComponent("mcp-results"))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("orchestrator-plan.unreadable.json").path))

        try send(.createSession, from: lead.id, in: store) { envelope in
            envelope.createPurpose = "review"
            envelope.createName = "Read only"
            envelope.createToolProfile = "readOnlyPrep"
        }
        let child = try XCTUnwrap(store.children(of: lead).first)
        store.terminateSession(id: child.id)
        // A history record knows nothing about the tool profile.
        _ = try store.resumeSession(from: SessionRestorationRecord(
            claudeSessionID: child.claudeSessionID, name: child.name, workingDirectory: directory, purpose: .review))
        XCTAssertTrue(launcher.arguments.contains("dontAsk"))
        XCTAssertFalse(launcher.arguments.contains("--dangerously-skip-permissions"))
    }

    func testAnsweringADecisionSavesItAndWakesTheOrchestrator() throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        var announced: [[Int]] = []
        store.openDecisionsObserver = { added, _ in announced.append(added.map(\.id)) }
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("decide"))
        try receive(.sessionStarted, from: lead.id, in: store)
        let root = try XCTUnwrap(store.writeOrchestratorBrief("Scan")).deletingLastPathComponent()
        let id = UUID().uuidString
        let plan = OrchestratorPlan(goal: "Ship", decisions: [
            .init(id: 1, question: "Push the branch?", options: ["yes", "hold"]),
            .init(id: 2, question: "Post the review?", options: ["yes", "hold"], answer: "hold"),
        ])
        try plan.json().write(to: root.appendingPathComponent("plan-update-\(id).json"))
        try send(.updatePlan, from: lead.id, in: store) { envelope in
            envelope.requestID = id
            envelope.planUpdateID = id
        }
        XCTAssertEqual(store.openDecisions.map(\.id), [1])
        XCTAssertEqual(announced, [[1]])

        XCTAssertEqual(store.discussWithOrchestrator(decision: 1), lead.id)
        let opened = try XCTUnwrap(relayNotes(for: lead.id, in: store).last)
        XCTAssertTrue(opened.contains("opened decision 1 (Push the branch?)"))
        XCTAssertTrue(opened.contains("give your recommendation"))
        XCTAssertTrue(store.openDecisions.count == 1, "discussing does not answer")
        try receive(.promptSubmitted, from: lead.id, in: store)
        try receive(.turnCompleted, from: lead.id, in: store)
        var ordered = OrchestratorPlan.Decision(id: 9, question: "Q", options: ["hold", "yes"])
        ordered.recommended = "yes"
        XCTAssertEqual(ordered.orderedOptions, ["yes", "hold"])
        XCTAssertThrowsError(try store.answerDecision(id: 1, option: "maybe"))
        try store.answerDecision(id: 1, option: "yes")
        XCTAssertTrue(store.openDecisions.isEmpty)
        let saved = try store.loadOrchestratorPlan()
        XCTAssertEqual(saved.decisions.first?.answer, "yes")
        XCTAssertEqual(saved.revision, 2)
        let note = try XCTUnwrap(relayNotes(for: lead.id, in: store).last)
        XCTAssertTrue(note.contains("answered decision 1"))
        XCTAssertTrue(note.contains("\"yes\""))
        XCTAssertThrowsError(try store.answerDecision(id: 1, option: "yes"))
    }

    func testHomeBoardEventsReportChangesOnlyBetweenSuccessfulReads() {
        func ticket(_ key: String, _ status: String) -> JiraTicketSummary {
            JiraTicketSummary(key: key, summary: "Fix login", status: status, priority: nil, updatedText: nil,
                              issueURL: URL(string: "https://jira.example/\(key)")!, sourceOrder: 0,
                              issueType: nil, fixVersion: nil)
        }
        func review(_ iid: String, pipeline: String?) -> MergeRequestSummary {
            let url = URL(string: "https://gitlab.example/mr/\(iid)")!
            return MergeRequestSummary(id: url, iidText: iid, title: "Add cache", projectDisplayName: nil,
                                       authorDisplayName: nil, isDraft: false, pipelineDisplayState: pipeline,
                                       reviewDisplayState: nil, updatedText: nil, mergeRequestURL: url, sourceOrder: 0)
        }
        var events = HomeBoardEvents()
        var snapshot = HomeBoardSnapshot(jiraTickets: [ticket("NMA-1", "To Do")], jiraStatus: .current,
                                         reviewItems: [review("7", pipeline: "Running")], reviewStatus: .current)
        XCTAssertEqual(events.observe(snapshot), [], "the first read is the baseline")

        snapshot.jiraStatus = HomeSourceStatus(check: .pending)
        snapshot.jiraTickets = []
        XCTAssertEqual(events.observe(snapshot), [], "a refresh in flight is not an empty board")

        snapshot.jiraStatus = .current
        snapshot.jiraTickets = [ticket("NMA-1", "In Progress"), ticket("NMA-2", "To Do")]
        snapshot.reviewItems = [review("7", pipeline: "Failed"), review("9", pipeline: nil)]
        XCTAssertEqual(events.observe(snapshot), [
            "NMA-1 moved from To Do to In Progress",
            "NMA-2 joined the board (To Do): Fix login",
            "!7 pipeline is now Failed",
            "review requested on !9: Add cache",
        ])
        snapshot.reviewItems = [review("9", pipeline: nil)]
        XCTAssertEqual(events.observe(snapshot), ["!7 left the review queue"])
    }

    func testOrchestratorLaunchesWithoutToolsThatDoWork() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let directory = tmpDirectory("manager")
        let lead = try startOrchestrator(in: store, directory: directory)
        let denied = try XCTUnwrap(launcher.arguments.firstIndex(of: "--disallowedTools"))
        for tool in ["Bash", "Edit", "NotebookEdit", "Agent", "Task"] {
            XCTAssertTrue(launcher.arguments[denied...].contains(tool), tool)
        }
        try send(.createSession, from: lead.id, in: store) { $0.createPurpose = "general" }
        XCTAssertFalse(launcher.arguments.contains("--disallowedTools"), "children keep their tools")
    }

    func testWatchedSessionRelaysFailureWithoutDirective() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let root = tmpDirectory("watch")
        let lead = try startOrchestrator(in: store, directory: root)
        let worker = try store.createSession(name: "Watched", workingDirectory: root)
        try receive(.sessionStarted, from: lead.id, in: store)
        try receive(.sessionStarted, from: worker, in: store)
        try send(.watchSession, from: lead.id, in: store) { $0.targetSessionID = worker.uuidString }
        try receive(.promptSubmitted, from: worker, in: store)
        try receive(.turnFailed, from: worker, in: store)
        try await Task.sleep(for: .seconds(SessionStore.relaySettleSeconds + 0.15))
        XCTAssertTrue(relayNotes(for: lead.id, in: store).last?.contains("failed.") == true)
    }

    func testRecentlyClosedChildCanResumeWithItsReadOnlyProfile() throws {
        let launcher = FakeLauncher()
        let store = makeStore(launcher: launcher)
        let directory = tmpDirectory("reopen")
        let lead = try startOrchestrator(in: store, directory: directory)
        try send(.createSession, from: lead.id, in: store) { envelope in
            envelope.createPurpose = "review"
            envelope.createName = "Review waiting on author"
            envelope.createModel = "fable"
            envelope.createToolProfile = "readOnlyPrep"
        }
        let original = try XCTUnwrap(store.children(of: lead).first)
        try receive(.sessionStarted, from: original.id, in: store)
        try receive(.promptSubmitted, from: original.id, in: store)
        try receive(.turnCompleted, from: original.id, in: store)
        store.terminateSession(id: original.id)
        XCTAssertNil(store.session(withID: original.id))

        let recent = try XCTUnwrap(store.recentlyClosedSessions.first)
        XCTAssertEqual(recent.id, original.claudeSessionID)
        XCTAssertEqual(recent.purpose, .review)
        let reopened = try XCTUnwrap(store.session(withID: store.resumeSession(from: recent)))
        XCTAssertEqual(reopened.claudeSessionID, original.claudeSessionID)
        XCTAssertEqual(reopened.parentClaudeSessionID, lead.claudeSessionID)
        XCTAssertEqual(reopened.model, "fable")
        XCTAssertTrue(launcher.arguments.contains("--resume"))
        XCTAssertTrue(launcher.arguments.contains("dontAsk"))
    }

    func testScheduledRecheckWakesIdleOrchestrator() async throws {
        let store = makeStore()
        store.queuedCommandSpacing = 0
        let lead = try startOrchestrator(in: store, directory: tmpDirectory("recheck"))
        try receive(.sessionStarted, from: lead.id, in: store)
        try send(.recheckIn, from: lead.id, in: store) { $0.recheckMinutes = 0.1 }
        let deadline = ContinuousClock.now + .seconds(8)
        while relayNotes(for: lead.id, in: store).isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(relayNotes(for: lead.id, in: store).last?.contains("scheduled recheck is due") == true)
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
        XCTAssertTrue(brief.contains("Worker"))
        XCTAssertTrue(brief.contains("orchestrator-run skill"))
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
        XCTAssertTrue(note.contains("Batch outward-facing decisions"))
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
        XCTAssertTrue(prompt.contains("what you are starting, then go"))
    }

    func testVersionComparisonHelpers() {
        XCTAssertEqual(ClaudeExecutableLocator.parseVersion(from: "claude 2.1.224 (Claude Code)"), "2.1.224")
        XCTAssertTrue(ClaudeExecutableLocator.isVersion("2.1.100", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.1.224", lessThan: "2.1.224"))
        XCTAssertFalse(ClaudeExecutableLocator.isVersion("2.2.0", lessThan: "2.1.224"))
    }
}
