import SwiftTerm
import XCTest
@testable import Console

/// End-to-end coordinator behavior on top of a fake launcher: typed requests,
/// the workspace resolution order, one-time choice learning, and proof that
/// WebView-derived source metadata never reaches Claude.
@MainActor
final class SessionLaunchCoordinatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var locatorDefaults: UserDefaults!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        suiteName = "SessionLaunchCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // Isolated locator defaults so tests never touch the hosted app's
        // real settings; a crashed run must not leak `/bin/echo` into Console.
        locatorDefaults = UserDefaults(suiteName: "SessionLaunchCoordinatorLocator-\(UUID().uuidString)")!
        locatorDefaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)

        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName!)
        try? FileManager.default.removeItem(at: tmpRoot!)
    }

    // MARK: - Fixtures

    private final class FakeLauncher: SessionProcessLaunching {
        var launchCount = 0
        var lastArguments: [String]?
        var lastEnvironment: [String: String]?
        var errorToThrow: Error?

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
            lastEnvironment = environment
            if let errorToThrow {
                throw errorToThrow
            }
        }
    }

    private struct SyntheticLaunchError: LocalizedError {
        var errorDescription: String? { "Synthetic launcher failed." }
    }

    private struct Stack {
        let store: SessionStore
        let workspaces: SessionWorkspaceStore
        let coordinator: SessionLaunchCoordinator
        let launcher: FakeLauncher
    }

    private func makeStack(locator: ClaudeExecutableLocator? = nil) -> Stack {
        let launcher = FakeLauncher()
        let store = SessionStore(
            launcher: launcher,
            locator: locator ?? ClaudeExecutableLocator(defaults: locatorDefaults)
        )
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

    private enum Sentinel {
        static let key = "SYN-99999"
        static let title = "SENTINEL-TITLE-ZXCVBNM"
        static let url = URL(string: "https://sentinel.example.test/browse/SYN-99999")!
        static let mrIID = "771337"
        static let mrTitle = "SENTINEL-MR-TITLE-QAZWSX"
        static let mrURL = URL(string: "https://sentinel.example.test/grp/proj/-/merge_requests/771337")!

        static var tokens: [String] {
            [
                key,
                title,
                url.absoluteString,
                "sentinel.example.test",
                mrTitle,
                mrURL.absoluteString,
                "Review !\(mrIID)",
                "merge_requests/\(mrIID)",
            ]
        }
    }

    private func jiraSource(_ key: String = "ENG-123") -> SessionLaunchSource {
        .jira(key: key, title: nil, url: URL(string: "https://example.test/browse/\(key)"))
    }

    private func mrSource(_ iid: String = "42") -> SessionLaunchSource {
        .mergeRequest(
            iid: iid,
            title: "Add SSO",
            url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/\(iid)")!
        )
    }

    private func sentinelJiraSource() -> SessionLaunchSource {
        .jira(key: Sentinel.key, title: Sentinel.title, url: Sentinel.url)
    }

    private func sentinelMRSource() -> SessionLaunchSource {
        .mergeRequest(iid: Sentinel.mrIID, title: Sentinel.mrTitle, url: Sentinel.mrURL)
    }

    private func assertSourceMetadataAbsent(
        from stack: Stack,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let argv = (stack.launcher.lastArguments ?? []).joined(separator: " ")
        let env = (stack.launcher.lastEnvironment ?? [:])
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let sends = stack.store.debugTerminalSendBytes.map(\.utf8).joined(separator: "\n")
        let combined = [argv, env, sends].joined(separator: "\n")
        for token in Sentinel.tokens {
            XCTAssertFalse(
                combined.contains(token),
                "source metadata leaked into argv/env/terminal-send: \(token)",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(argv.contains("--name"), "local display names must not be passed as --name", file: file, line: line)
        XCTAssertTrue(stack.store.debugTerminalSendBytes.isEmpty, "contextual launches must not send terminal bytes", file: file, line: line)
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

    func testCreateSessionRequestStoresPurposeAndLocalArtifact() throws {
        let stack = makeStack()
        let directory = tmpRoot!.appendingPathComponent("Req", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = try stack.store.createSession(request: SessionCreationRequest(
            purpose: .existingTicket,
            name: Sentinel.key,
            workingDirectory: directory,
            source: sentinelJiraSource()
        ))

        let session = try XCTUnwrap(stack.store.session(withID: id))
        XCTAssertEqual(session.purpose, .existingTicket)
        XCTAssertEqual(session.name, Sentinel.key, "local display may show the issue key")
        XCTAssertTrue(session.artifacts.contains { $0.kind == .jiraIssue && $0.label == Sentinel.key })
        XCTAssertEqual(session.activity, .starting)
        assertSourceMetadataAbsent(from: stack)
    }

    func testLegacyCreateOverloadStillWorksAsCompatibilityWrapper() throws {
        let stack = makeStack()
        let directory = tmpRoot!.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = try stack.store.createSession(name: "Old", workingDirectory: directory)

        let session = try XCTUnwrap(stack.store.session(withID: id))
        XCTAssertEqual(session.name, "Old")
        XCTAssertEqual(session.purpose, .general, "legacy sessions are General-purpose")
        XCTAssertTrue(session.artifacts.isEmpty)
        XCTAssertTrue(stack.store.debugTerminalSendBytes.isEmpty)
    }

    func testReviewLaunchOmitsSourceMetadataFromArgvAndEnvironment() throws {
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
        XCTAssertFalse(joinedArgs.contains("--name"))
        XCTAssertFalse(joinedArgs.contains("Review GitLab merge request"), "no source-derived prompt body")
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

    // MARK: - Source metadata stays local

    func testToolbarAndCardJiraLaunchKeepsSentinelOutOfClaude() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "JiraHome")

        stack.coordinator.beginJiraTicketLaunch(
            key: Sentinel.key,
            title: Sentinel.title,
            url: Sentinel.url
        )

        let session = try XCTUnwrap(stack.store.selectedSession)
        XCTAssertEqual(session.name, Sentinel.key)
        XCTAssertTrue(session.artifacts.contains { $0.label == Sentinel.key && $0.kind == .jiraIssue })
        XCTAssertEqual(session.activity, .starting)

        receiveLifecycleEvent(stack, sessionID: session.id, event: .sessionStarted, eventID: "evt-jira-auto")
        XCTAssertEqual(stack.store.session(withID: session.id)?.activity, .idle, "contextual launches stay idle")
        assertSourceMetadataAbsent(from: stack)
    }

    func testToolbarMergeRequestLaunchKeepsSentinelOutOfClaude() throws {
        let stack = makeStack()
        addWorkspace(
            stack,
            named: "ReviewHome",
            gitRemote: "https://sentinel.example.test/grp/proj.git"
        )

        stack.coordinator.beginMergeRequestReview(
            iid: Sentinel.mrIID,
            title: Sentinel.mrTitle,
            url: Sentinel.mrURL
        )

        let session = try XCTUnwrap(stack.store.selectedSession)
        XCTAssertEqual(session.name, "Review !\(Sentinel.mrIID)")
        XCTAssertTrue(session.artifacts.contains { $0.label == "MR !\(Sentinel.mrIID)" })

        receiveLifecycleEvent(stack, sessionID: session.id, event: .sessionStarted, eventID: "evt-mr-auto")
        XCTAssertEqual(stack.store.session(withID: session.id)?.activity, .idle)
        assertSourceMetadataAbsent(from: stack)
    }

    func testRetainedPageDraftLaunchKeepsSentinelOutOfClaude() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Retained")

        let draft = stack.coordinator.draft(purpose: .existingTicket, source: sentinelJiraSource())
        XCTAssertEqual(draft.name, Sentinel.key)
        XCTAssertNil(StarterPromptBuilder.prompt(for: draft.purpose, source: draft.source))

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: draft))
        let session = try XCTUnwrap(stack.store.session(withID: id))
        XCTAssertEqual(session.name, Sentinel.key)

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-retained-auto")
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .idle)
        assertSourceMetadataAbsent(from: stack)
    }

    func testManualPathHasNothingSourceDerivedToSend() throws {
        let stack = makeStack()
        addWorkspace(
            stack,
            named: "Manual",
            gitRemote: "https://sentinel.example.test/grp/proj.git"
        )

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: sentinelMRSource()
        )))

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-manual-idle")
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .idle)
        XCTAssertTrue(stack.store.debugTerminalSendBytes.isEmpty, "no queued prompt exists to send manually")
        assertSourceMetadataAbsent(from: stack)
    }

    func testGeneralSessionRemainsUsableAndSendsOnlyExplicitPrompts() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "GeneralHome")

        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .general,
            source: nil
        )))

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-general-start")
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .idle)
        XCTAssertTrue(stack.store.debugTerminalSendBytes.isEmpty)

        XCTAssertEqual(stack.store.submit(prompt: "please list the files", to: id), .submitted)
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .working)
        XCTAssertFalse(stack.store.debugTerminalSendBytes.isEmpty)
        let sent = stack.store.debugTerminalSendBytes.map(\.utf8).joined()
        XCTAssertTrue(sent.contains("please list the files"))
        for token in Sentinel.tokens {
            XCTAssertFalse(sent.contains(token))
        }
    }

    func testStopStillExitsAContextualSession() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Stopped")
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .existingTicket,
            source: sentinelJiraSource()
        )))

        stack.store.stopSession(id: id)

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .exited)
        assertSourceMetadataAbsent(from: stack)
    }

    func testTurnFailureMarksErrorWithoutSendingSource() throws {
        let stack = makeStack()
        addWorkspace(
            stack,
            named: "Failed",
            gitRemote: "https://sentinel.example.test/grp/proj.git"
        )
        let id = try XCTUnwrap(try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: sentinelMRSource()
        )))

        receiveLifecycleEvent(stack, sessionID: id, event: .turnFailed, eventID: "evt-fail-1")

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .error)
        assertSourceMetadataAbsent(from: stack)
    }

    // MARK: - Launch failures stay visible and do not learn routing

    func testMissingClaudeOnContextualLaunchSurfacesFailureWithoutLearning() throws {
        locatorDefaults.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        let notFound = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [] },
            defaults: locatorDefaults
        )
        let stack = makeStack(locator: notFound)
        addWorkspace(stack, named: "Home")
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)

        XCTAssertTrue(stack.coordinator.lastFailureMessage?.contains("Claude") == true)
        XCTAssertEqual(stack.coordinator.lastFailure?.offersSettingsRoute, true)
        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertFalse(stack.coordinator.presentsChoiceSheet)
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket))
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"))
        XCTAssertEqual(stack.launcher.launchCount, 0)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            sidebarBefore,
            "failed contextual launches must not navigate as if successful"
        )
    }

    func testDisappearingFolderOverrideThrowsActionableError() throws {
        let stack = makeStack()
        let vanished = addWorkspace(stack, named: "Vanished")
        var draft = stack.coordinator.draft(purpose: .general, source: nil)
        draft.workspaceID = vanished.id
        try FileManager.default.removeItem(at: vanished.directoryURL)

        XCTAssertThrowsError(try stack.coordinator.launch(draft: draft)) { error in
            XCTAssertEqual(error as? SessionLaunchCoordinator.LaunchError, .workspaceUnavailable)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Settings") == true)
        }
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .general))
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testNonGitReviewOverrideThrowsActionableError() throws {
        let stack = makeStack()
        let plain = addWorkspace(stack, named: "PlainOnly")
        var draft = stack.coordinator.draft(purpose: .review, source: mrSource("7"))
        draft.workspaceID = plain.id

        XCTAssertFalse(stack.coordinator.canConfirmWorkspace(workspaceID: plain.id, purpose: .review))
        XCTAssertTrue(
            stack.coordinator.workspaceBlockingReason(workspaceID: plain.id, purpose: .review)?
                .contains("Git") == true
        )
        XCTAssertThrowsError(try stack.coordinator.launch(draft: draft)) { error in
            XCTAssertEqual(error as? SessionLaunchCoordinator.LaunchError, .workspaceNotAGitRepository)
        }
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .review))
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"))
    }

    func testInjectedLauncherFailureSurfacesErrorWithoutLearningOrNavigating() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Home")
        stack.launcher.errorToThrow = SyntheticLaunchError()
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        stack.coordinator.beginJiraTicketLaunch(
            key: Sentinel.key,
            title: Sentinel.title,
            url: Sentinel.url
        )

        XCTAssertEqual(stack.coordinator.lastFailureMessage, "Synthetic launcher failed.")
        XCTAssertEqual(stack.coordinator.lastFailure?.offersSettingsRoute, true)
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket))
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "SYN"))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            sidebarBefore
        )
        assertSourceMetadataAbsent(from: stack)
    }

    func testSuccessfulRetryAfterLauncherFailureClearsErrorAndThenLearns() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Home")
        stack.launcher.errorToThrow = SyntheticLaunchError()

        stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)
        XCTAssertNotNil(stack.coordinator.lastFailureMessage)
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"))

        stack.launcher.errorToThrow = nil
        stack.coordinator.beginJiraTicketLaunch(key: "ENG-456", title: nil, url: nil)

        XCTAssertNil(stack.coordinator.lastFailureMessage)
        XCTAssertNotNil(stack.store.selectedSession)
        XCTAssertEqual(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"), stack.workspaces.workspaces.first?.id)
        XCTAssertEqual(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket), stack.workspaces.workspaces.first?.id)
    }

    func testCancelClearsPendingChoiceAndFailure() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Home")
        stack.workspaces.setDefault(id: nil)

        let unresolved = try stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .existingTicket,
            source: jiraSource()
        ))
        XCTAssertNil(unresolved)
        XCTAssertNotNil(stack.coordinator.pendingChoice)
        stack.coordinator.cancelWorkspaceChoice()

        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertFalse(stack.coordinator.presentsChoiceSheet)
        XCTAssertNil(stack.coordinator.lastFailureMessage)
    }
}
