import SwiftTerm
import XCTest
@testable import Console

/// End-to-end coordinator behavior on top of a fake launcher: typed requests,
/// the workspace resolution order, one-time choice learning, and memory-only
/// starter prompt delivery.
@MainActor
final class SessionLaunchCoordinatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var storedOverrideBefore: String?
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        suiteName = "SessionLaunchCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        storedOverrideBefore = UserDefaults.standard.string(forKey: ClaudeExecutableLocator.settingsKey)
        UserDefaults.standard.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)

        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let storedOverrideBefore {
            UserDefaults.standard.set(storedOverrideBefore, forKey: ClaudeExecutableLocator.settingsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - Fixtures

    private final class FakeLauncher: SessionProcessLaunching {
        var launchCount = 0
        var lastArguments: [String]?

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
            lastArguments = arguments
        }
    }

    private struct Stack {
        let store: SessionStore
        let workspaces: SessionWorkspaceStore
        let coordinator: SessionLaunchCoordinator
        let launcher: FakeLauncher
    }

    private func makeStack() -> Stack {
        let launcher = FakeLauncher()
        let store = SessionStore(launcher: launcher)
        let workspaces = SessionWorkspaceStore(defaults: defaults!)
        let coordinator = SessionLaunchCoordinator(store: store, workspaceStore: workspaces)
        return Stack(store: store, workspaces: workspaces, coordinator: coordinator, launcher: launcher)
    }

    @discardableResult
    private func addWorkspace(
        _ stack: Stack,
        named name: String,
        gitRemote remote: String? = nil
    ) -> SessionWorkspace {
        let directory = tmpRoot!.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let remote {
            let gitDir = directory.appendingPathComponent(".git", isDirectory: true)
            try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
            let config = """
            [core]
                repositoryformatversion = 0
            [remote "origin"]
                url = \(remote)

            """
            try? config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        return stack.workspaces.add(name: name, directoryURL: directory)
    }

    private func jiraSource(_ key: String = "ENG-123") -> SessionLaunchSource {
        .jira(key: key, title: nil, url: URL(string: "https://acme.atlassian.net/browse/\(key)"))
    }

    private func mrSource(_ iid: String = "42") -> SessionLaunchSource {
        .mergeRequest(
            host: .gitlab,
            iid: iid,
            title: "Add SSO",
            url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/\(iid)")!
        )
    }

    /// Feeds a validated lifecycle envelope as if it arrived over the bridge.
    private func receiveLifecycleEvent(_ stack: Stack, sessionID: UUID, event: BridgeProtocol.LifecycleEventKind, eventID: String) {
        guard let token = stack.store.debugSessionToken(sessionID) else {
            XCTFail("missing bridge token for \(sessionID)")
            return
        }
        stack.store.debugReceiveEnvelope(BridgeEnvelope(
            sessionID: sessionID.uuidString,
            token: token,
            eventID: eventID,
            kind: .lifecycle,
            lifecycleEvent: event
        ))
    }

    // MARK: - Typed creation request

    func testCreateSessionRequestStoresPurposeArtifactAndPrompt() throws {
        let stack = makeStack()
        let directory = tmpRoot!.appendingPathComponent("Req", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = try stack.store.createSession(request: SessionCreationRequest(
            purpose: .existingTicket,
            name: "ENG-123",
            workingDirectory: directory,
            source: jiraSource(),
            starterPrompt: "Work on Jira ticket ENG-123"
        ))

        let session = try XCTUnwrap(stack.store.session(withID: id))
        XCTAssertEqual(session.purpose, .existingTicket)
        XCTAssertTrue(session.artifacts.contains { $0.kind == .jiraIssue && $0.label == "ENG-123" })
        XCTAssertEqual(session.pendingStarterPrompt, "Work on Jira ticket ENG-123")
        XCTAssertEqual(session.activity, .starting)
    }

    func testLegacyCreateOverloadStillWorksAsCompatibilityWrapper() throws {
        let stack = makeStack()
        let directory = tmpRoot!.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = try stack.store.createSession(name: "Old", workingDirectory: directory)

        let session = try XCTUnwrap(stack.store.session(withID: id))
        XCTAssertEqual(session.name, "Old")
        XCTAssertEqual(session.purpose, .general, "legacy sessions are General-purpose")
        XCTAssertNil(session.pendingStarterPrompt)
        XCTAssertTrue(session.artifacts.isEmpty)
    }

    func testStarterPromptNeverAppearsInLaunchArgumentsOrEnvironmentKeys() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Private", gitRemote: "https://gitlab.com/grp/proj.git")

        _ = try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        ))

        XCTAssertTrue((stack.launcher.lastArguments ?? []).count > 0)
        let joinedArgs = (stack.launcher.lastArguments ?? []).joined(separator: " ")
        XCTAssertFalse(joinedArgs.contains("Add SSO"), "MR title stays out of launch arguments")
        XCTAssertFalse(joinedArgs.contains("gitlab.com/grp/proj"))
        XCTAssertFalse(joinedArgs.contains("Review GitLab merge request"), "the prompt body never reaches argv")
    }

    // MARK: - Resolution order

    func testExplicitWorkspaceOverrideBeatsRememberedAssociation() throws {
        let stack = makeStack()
        let associated = addWorkspace(stack, named: "Associated")
        let override = addWorkspace(stack, named: "Override")
        stack.workspaces.rememberAssociation(routingIdentity: "ENG", workspaceID: associated.id)

        var draft = stack.coordinator.draft(purpose: .existingTicket, source: jiraSource())
        draft.workspaceID = override.id
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: draft))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, override.directoryURL.standardizedFileURL.path)
        // Overrides do not rewrite what was learned about the source.
        XCTAssertEqual(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"), associated.id)
    }

    func testRememberedAssociationLaunchesOneClickWithoutChoiceSheet() throws {
        let stack = makeStack()
        let home = addWorkspace(stack, named: "Home")

        // First launch: unresolved → one-time choice.
        var firstDraft = stack.coordinator.draft(purpose: .existingTicket, source: jiraSource())
        firstDraft.workspaceID = home.id
        _ = try stack.coordinator.launch(draft: firstDraft)

        stack.coordinator.cancelWorkspaceChoice()

        // Second launch of the same project resolves through the association.
        let second = stack.coordinator.draft(purpose: .existingTicket, source: jiraSource("ENG-456"))
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: second))

        XCTAssertNil(stack.coordinator.pendingChoice, "mapped tickets never ask again")
        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, home.directoryURL.standardizedFileURL.path)
    }

    func testUniqueRemoteMatchResolvesReviewToTheGitRepository() throws {
        let stack = makeStack()
        let repo = addWorkspace(stack, named: "Repo", gitRemote: "https://gitlab.com/grp/proj.git")
        addWorkspace(stack, named: "Plain")

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        )))

        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, repo.directoryURL.standardizedFileURL.path)
        // The unique match is remembered for next time.
        XCTAssertEqual(
            stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"),
            repo.id
        )
    }

    func testAmbiguousRemoteMatchAsksOnceAndConfirmLearns() throws {
        let stack = makeStack()
        let alpha = addWorkspace(stack, named: "Alpha", gitRemote: "https://gitlab.com/grp/proj.git")
        let beta = addWorkspace(stack, named: "Beta", gitRemote: "git@gitlab.com:grp/proj.git")
        // Remove the automatic first-workspace default so neither repo wins
        // via the fallback steps; only the ambiguous match is in play.
        stack.workspaces.setDefault(id: nil)

        let unresolved = try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        ))
        XCTAssertNil(unresolved)
        let choice = try XCTUnwrap(stack.coordinator.pendingChoice)

        let confirmedID = try XCTUnwrap(try stack.coordinator.confirmWorkspaceChoice(workspaceID: beta.id))
        XCTAssertNotNil(stack.store.session(withID: confirmedID), "confirmation launches the session")
        XCTAssertNil(stack.coordinator.pendingChoice)
        _ = choice

        // Learned: next identical source skips the sheet entirely.
        _ = try stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .review, source: mrSource()))
        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertEqual(
            stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"),
            beta.id
        )
        _ = alpha
    }

    func testSelectedSessionContainingWorkspaceWinsForGeneralPurpose() throws {
        let stack = makeStack()
        let monorepo = addWorkspace(stack, named: "Monorepo")
        let other = addWorkspace(stack, named: "Other")

        let nestedDirectory = monorepo.directoryURL.appendingPathComponent("Subproject", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let baseID = try stack.store.createSession(name: "Base", workingDirectory: nestedDirectory)
        stack.store.select(sessionID: baseID)

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .general, source: nil)))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, monorepo.directoryURL.standardizedFileURL.path)
        XCTAssertNotEqual(stack.store.session(withID: id)?.workingDirectory.lastPathComponent, other.name)
    }

    func testLastUsedPerPurposeBeatsGlobalDefault() throws {
        let stack = makeStack()
        let defaultHome = addWorkspace(stack, named: "DefaultHome")
        let reviewHome = addWorkspace(stack, named: "ReviewHome", gitRemote: "https://gitlab.com/elsewhere/repo.git")
        stack.workspaces.setDefault(id: defaultHome.id)
        stack.workspaces.noteUse(workspaceID: reviewHome.id, purpose: .review)

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource("99") // no association, no remote match
        )))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, reviewHome.directoryURL.standardizedFileURL.path)
    }

    func testDefaultWorkspaceIsTheFinalFallbackBeforeAsking() throws {
        let stack = makeStack()
        let fallback = addWorkspace(stack, named: "Fallback")
        stack.workspaces.setDefault(id: fallback.id)

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .newTicket, source: nil)))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, fallback.directoryURL.standardizedFileURL.path)
    }

    func testUnavailableDefaultIsSkippedAndChoiceIsPresented() throws {
        let stack = makeStack()
        let vanished = addWorkspace(stack, named: "Vanished")
        stack.workspaces.setDefault(id: vanished.id)
        try FileManager.default.removeItem(at: vanished.directoryURL)

        let result = try stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .newTicket, source: nil))

        XCTAssertNil(result)
        XCTAssertEqual(stack.coordinator.pendingChoice?.purpose, .newTicket)
    }

    func testReviewSkipsNonGitWorkspacesWhenResolving() throws {
        let stack = makeStack()
        let plain = addWorkspace(stack, named: "PlainOnly")
        stack.workspaces.setDefault(id: plain.id)
        stack.workspaces.noteUse(workspaceID: plain.id, purpose: .review)

        let result = try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource("7")
        ))

        // The non-git folder cannot host reviews, so the chooser appears even
        // though it is default and last-used for this purpose.
        XCTAssertNil(result)
        XCTAssertEqual(stack.coordinator.pendingChoice?.purpose, .review)
    }

    // MARK: - Starter prompt delivery

    func testStarterPromptSubmitsExactlyOnceAfterSessionStarted() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Deliver")
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .existingTicket,
            source: jiraSource()
        )))

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .starting)
        XCTAssertNotNil(stack.store.pendingStarterPrompt(for: id), "prompt queues while starting")

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-start-1")

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .working, "delivery applies the optimistic promptSubmitted state")
        XCTAssertNil(stack.store.pendingStarterPrompt(for: id), "the queue drains on first delivery")

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-start-2")
        XCTAssertNil(stack.store.pendingStarterPrompt(for: id), "a repeated start has nothing left to deliver")
    }

    func testDisabledAutoStartKeepsPromptPendingForManualSend() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Manual", gitRemote: "https://gitlab.com/grp/proj.git")
        stack.workspaces.automaticallyStartsContextualWork = false

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        )))

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-manual-start")
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .idle, "auto-start off leaves the session idle")
        XCTAssertNotNil(stack.store.pendingStarterPrompt(for: id), "banner keeps the manual-send prompt")

        let result = stack.coordinator.manuallySendStarterPrompt(to: id)

        XCTAssertEqual(result, SubmissionResult.submitted)
        XCTAssertNil(stack.store.pendingStarterPrompt(for: id))
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .working)
    }

    func testManualSendBypassesIdleGateWhileBridgeUnavailable() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "NoBridge", gitRemote: "https://gitlab.com/grp/proj.git")
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        )))

        // Bridge never reports anything, so the activity stays .starting and
        // the ordinary submit gate would refuse; manual send must not.
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .starting)

        let result = stack.coordinator.manuallySendStarterPrompt(to: id)

        XCTAssertEqual(result, SubmissionResult.submitted)
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .working)
        XCTAssertNil(stack.store.pendingStarterPrompt(for: id))
    }

    func testStopClearsTheQueuedPrompt() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Stopped")
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .existingTicket,
            source: jiraSource()
        )))
        XCTAssertNotNil(stack.store.pendingStarterPrompt(for: id))

        stack.store.stopSession(id: id) // no live process → immediate terminated event

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .exited)
        XCTAssertNil(stack.store.pendingStarterPrompt(for: id))
    }

    func testTurnFailureClearsTheQueuedPrompt() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Failed", gitRemote: "https://gitlab.com/grp/proj.git")
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        )))
        XCTAssertNotNil(stack.store.pendingStarterPrompt(for: id))

        receiveLifecycleEvent(stack, sessionID: id, event: .turnFailed, eventID: "evt-fail-1")

        XCTAssertNil(stack.store.pendingStarterPrompt(for: id))
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .error)
    }
}
