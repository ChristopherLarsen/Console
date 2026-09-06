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

    private final class FakeAssembler: ConsoleClaudePluginAssembling {
        var errorToThrow: Error? = ConsoleClaudePluginAssembler.AssemblyError.missingResource("synthetic-plugin")

        func materialize(in baseDirectory: URL) throws -> URL {
            if let errorToThrow {
                throw errorToThrow
            }
            return try ConsoleClaudePluginAssembler().materialize(in: baseDirectory)
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

    private func makeStack(
        locator: ClaudeExecutableLocator? = nil,
        pluginAssembler: (any ConsoleClaudePluginAssembling)? = nil
    ) -> Stack {
        let launcher = FakeLauncher()
        let store = SessionStore(
            launcher: launcher,
            locator: locator ?? ClaudeExecutableLocator(defaults: locatorDefaults),
            pluginAssembler: pluginAssembler ?? ConsoleClaudePluginAssembler()
        )
        let workspaces = SessionWorkspaceStore(defaults: defaults!)
        let coordinator = SessionLaunchCoordinator(store: store, workspaceStore: workspaces)
        return Stack(store: store, workspaces: workspaces, coordinator: coordinator, launcher: launcher)
    }

    private struct GitFixtureError: Error {}

    private func initializeLocalGitRemote(at directory: URL, remote: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitFixtureError() }

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["remote", "add", "origin", remote]
        add.currentDirectoryURL = directory
        add.environment = environment
        let addPipe = Pipe()
        add.standardOutput = addPipe
        add.standardError = addPipe
        add.standardInput = FileHandle.nullDevice
        try add.run()
        _ = addPipe.fileHandleForReading.readDataToEndOfFile()
        add.waitUntilExit()
        guard add.terminationStatus == 0 else { throw GitFixtureError() }
    }

    @discardableResult
    private func addWorkspace(
        _ stack: Stack,
        named name: String,
        gitRemote remote: String? = nil
    ) throws -> SessionWorkspace {
        let directory = tmpRoot!.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let remote {
            try initializeLocalGitRemote(at: directory, remote: remote)
        }
        return stack.workspaces.add(name: name, directoryURL: directory)
    }

    private func requireLaunch(_ stack: Stack, draft: SessionDraft) async throws -> UUID {
        let sessionID = try await stack.coordinator.launch(draft: draft)
        return try XCTUnwrap(sessionID)
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

    func testCreateSessionRequestStoresPurposeAndLocalArtifact() async throws {
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

    func testLegacyCreateOverloadStillWorksAsCompatibilityWrapper() async throws {
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

    func testReviewLaunchOmitsSourceMetadataFromArgvAndEnvironment() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Private", gitRemote: "https://gitlab.com/grp/proj.git")

        _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(
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

    func testExplicitWorkspaceOverrideBeatsRememberedAssociation() async throws {
        let stack = makeStack()
        let associated = try addWorkspace(stack, named: "Associated")
        let override = try addWorkspace(stack, named: "Override")
        stack.workspaces.rememberAssociation(routingIdentity: "ENG", workspaceID: associated.id)

        var draft = stack.coordinator.draft(purpose: .existingTicket, source: jiraSource())
        draft.workspaceID = override.id
        let id = try await requireLaunch(stack, draft: draft)

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, override.directoryURL.standardizedFileURL.path)
        // Overrides do not rewrite what was learned about the source.
        XCTAssertEqual(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"), associated.id)
    }

    func testRememberedAssociationLaunchesOneClickWithoutChoiceSheet() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "Home")

        // First launch: unresolved → one-time choice.
        var firstDraft = stack.coordinator.draft(purpose: .existingTicket, source: jiraSource())
        firstDraft.workspaceID = home.id
        let firstID = try await requireLaunch(stack, draft: firstDraft)
        stack.store.stopSession(id: firstID)

        stack.coordinator.cancelWorkspaceChoice()

        // Second launch of the same project resolves through the association.
        // The first session is exited so occupancy does not mask routing.
        let second = stack.coordinator.draft(purpose: .existingTicket, source: jiraSource("ENG-456"))
        let id = try await requireLaunch(stack, draft: second)

        XCTAssertNil(stack.coordinator.pendingChoice, "mapped tickets never ask again")
        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, home.directoryURL.standardizedFileURL.path)
    }

    func testUniqueRemoteMatchResolvesReviewToTheGitRepository() async throws {
        let stack = makeStack()
        let repo = try addWorkspace(stack, named: "Repo", gitRemote: "https://gitlab.com/grp/proj.git")
        try addWorkspace(stack, named: "Plain")

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        ))

        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, repo.directoryURL.standardizedFileURL.path)
        // The unique match is remembered for next time.
        XCTAssertEqual(
            stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"),
            repo.id
        )
    }

    func testAmbiguousRemoteMatchAsksOnceAndConfirmLearns() async throws {
        let stack = makeStack()
        let alpha = try addWorkspace(stack, named: "Alpha", gitRemote: "https://gitlab.com/grp/proj.git")
        let beta = try addWorkspace(stack, named: "Beta", gitRemote: "git@gitlab.com:grp/proj.git")
        // Remove the automatic first-workspace default so neither repo wins
        // via the fallback steps; only the ambiguous match is in play.
        stack.workspaces.setDefault(id: nil)

        let unresolved = try await stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource()
        ))
        XCTAssertNil(unresolved)
        let choice = try XCTUnwrap(stack.coordinator.pendingChoice)

        let confirmed = try await stack.coordinator.confirmWorkspaceChoice(workspaceID: beta.id)
        let confirmedID = try XCTUnwrap(confirmed)
        XCTAssertNotNil(stack.store.session(withID: confirmedID), "confirmation launches the session")
        XCTAssertNil(stack.coordinator.pendingChoice)
        _ = choice
        stack.store.stopSession(id: confirmedID)

        // Learned: next identical source skips the sheet entirely.
        _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .review, source: mrSource()))
        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertEqual(
            stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"),
            beta.id
        )
        _ = alpha
    }

    func testSelectedSessionContainingWorkspaceWinsForGeneralPurpose() async throws {
        let stack = makeStack()
        let monorepo = try addWorkspace(stack, named: "Monorepo")
        let other = try addWorkspace(stack, named: "Other")

        let nestedDirectory = monorepo.directoryURL.appendingPathComponent("Subproject", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let baseID = try stack.store.createSession(name: "Base", workingDirectory: nestedDirectory)
        stack.store.select(sessionID: baseID)

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(purpose: .general, source: nil))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, monorepo.directoryURL.standardizedFileURL.path)
        XCTAssertNotEqual(stack.store.session(withID: id)?.workingDirectory.lastPathComponent, other.name)
    }

    func testLastUsedPerPurposeBeatsGlobalDefault() async throws {
        let stack = makeStack()
        let defaultHome = try addWorkspace(stack, named: "DefaultHome")
        let reviewHome = try addWorkspace(stack, named: "ReviewHome", gitRemote: "https://gitlab.com/elsewhere/repo.git")
        stack.workspaces.setDefault(id: defaultHome.id)
        stack.workspaces.noteUse(workspaceID: reviewHome.id, purpose: .review)

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource("99") // no association, no remote match
        ))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, reviewHome.directoryURL.standardizedFileURL.path)
    }

    func testDefaultWorkspaceIsTheFinalFallbackBeforeAsking() async throws {
        let stack = makeStack()
        let fallback = try addWorkspace(stack, named: "Fallback")
        stack.workspaces.setDefault(id: fallback.id)

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(purpose: .newTicket, source: nil))

        XCTAssertEqual(stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path, fallback.directoryURL.standardizedFileURL.path)
    }

    func testUnavailableDefaultIsSkippedAndChoiceIsPresented() async throws {
        let stack = makeStack()
        let vanished = try addWorkspace(stack, named: "Vanished")
        stack.workspaces.setDefault(id: vanished.id)
        try FileManager.default.removeItem(at: vanished.directoryURL)

        let result = try await stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .newTicket, source: nil))

        XCTAssertNil(result)
        XCTAssertEqual(stack.coordinator.pendingChoice?.purpose, .newTicket)
    }

    func testReviewSkipsNonGitWorkspacesWhenResolving() async throws {
        let stack = makeStack()
        let plain = try addWorkspace(stack, named: "PlainOnly")
        stack.workspaces.setDefault(id: plain.id)
        stack.workspaces.noteUse(workspaceID: plain.id, purpose: .review)

        let result = try await stack.coordinator.launch(draft: stack.coordinator.draft(
            purpose: .review,
            source: mrSource("7")
        ))

        // The non-git folder cannot host reviews, so the chooser appears even
        // though it is default and last-used for this purpose.
        XCTAssertNil(result)
        XCTAssertEqual(stack.coordinator.pendingChoice?.purpose, .review)
    }

    // MARK: - Source metadata stays local

    func testToolbarAndCardJiraLaunchKeepsSentinelOutOfClaude() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "JiraHome")

        await stack.coordinator.beginJiraTicketLaunch(
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

    func testToolbarMergeRequestLaunchKeepsSentinelOutOfClaude() async throws {
        let stack = makeStack()
        try addWorkspace(
            stack,
            named: "ReviewHome",
            gitRemote: "https://sentinel.example.test/grp/proj.git"
        )

        await stack.coordinator.beginMergeRequestReview(
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

    func testRetainedPageDraftLaunchKeepsSentinelOutOfClaude() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Retained")

        let draft = stack.coordinator.draft(purpose: .existingTicket, source: sentinelJiraSource())
        XCTAssertEqual(draft.name, Sentinel.key)
        XCTAssertNil(StarterPromptBuilder.prompt(for: draft.purpose, source: draft.source))

        let id = try await requireLaunch(stack, draft: draft)
        let session = try XCTUnwrap(stack.store.session(withID: id))
        XCTAssertEqual(session.name, Sentinel.key)

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-retained-auto")
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .idle)
        assertSourceMetadataAbsent(from: stack)
    }

    func testManualPathHasNothingSourceDerivedToSend() async throws {
        let stack = makeStack()
        try addWorkspace(
            stack,
            named: "Manual",
            gitRemote: "https://sentinel.example.test/grp/proj.git"
        )

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(
            purpose: .review,
            source: sentinelMRSource()
        ))

        receiveLifecycleEvent(stack, sessionID: id, event: .sessionStarted, eventID: "evt-manual-idle")
        XCTAssertEqual(stack.store.session(withID: id)?.activity, .idle)
        XCTAssertTrue(stack.store.debugTerminalSendBytes.isEmpty, "no queued prompt exists to send manually")
        assertSourceMetadataAbsent(from: stack)
    }

    func testGeneralSessionRemainsUsableAndSendsOnlyExplicitPrompts() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "GeneralHome")

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(
            purpose: .general,
            source: nil
        ))

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

    func testStopStillExitsAContextualSession() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Stopped")
        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(
            purpose: .existingTicket,
            source: sentinelJiraSource()
        ))

        stack.store.stopSession(id: id)

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .exited)
        assertSourceMetadataAbsent(from: stack)
    }

    func testTurnFailureMarksErrorWithoutSendingSource() async throws {
        let stack = makeStack()
        try addWorkspace(
            stack,
            named: "Failed",
            gitRemote: "https://sentinel.example.test/grp/proj.git"
        )
        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(
            purpose: .review,
            source: sentinelMRSource()
        ))

        receiveLifecycleEvent(stack, sessionID: id, event: .turnFailed, eventID: "evt-fail-1")

        XCTAssertEqual(stack.store.session(withID: id)?.activity, .error)
        assertSourceMetadataAbsent(from: stack)
    }

    // MARK: - Launch failures stay visible and do not learn routing

    func testMissingClaudeOnContextualLaunchSurfacesFailureWithoutLearning() async throws {
        locatorDefaults.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        let notFound = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [] },
            defaults: locatorDefaults
        )
        let stack = makeStack(locator: notFound)
        try addWorkspace(stack, named: "Home")
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)

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

    func testDisappearingFolderOverrideThrowsActionableError() async throws {
        let stack = makeStack()
        let vanished = try addWorkspace(stack, named: "Vanished")
        var draft = stack.coordinator.draft(purpose: .general, source: nil)
        draft.workspaceID = vanished.id
        try FileManager.default.removeItem(at: vanished.directoryURL)

        do {
            _ = try await stack.coordinator.launch(draft: draft)
            XCTFail("expected disappearing folder to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .workspaceUnavailable)
            XCTAssertTrue(error.errorDescription?.contains("Settings") == true)
        }
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .general))
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testNonGitReviewOverrideThrowsActionableError() async throws {
        let stack = makeStack()
        let plain = try addWorkspace(stack, named: "PlainOnly")
        var draft = stack.coordinator.draft(purpose: .review, source: mrSource("7"))
        draft.workspaceID = plain.id

        XCTAssertFalse(stack.coordinator.canConfirmWorkspace(workspaceID: plain.id, purpose: .review))
        XCTAssertTrue(
            stack.coordinator.workspaceBlockingReason(workspaceID: plain.id, purpose: .review)?
                .contains("Git") == true
        )
        do {
            _ = try await stack.coordinator.launch(draft: draft)
            XCTFail("expected non-git review override to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .workspaceNotAGitRepository)
        }
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .review))
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"))
    }

    func testInjectedLauncherFailureSurfacesErrorWithoutLearningOrNavigating() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Home")
        stack.launcher.errorToThrow = SyntheticLaunchError()
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        await stack.coordinator.beginJiraTicketLaunch(
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
        XCTAssertTrue(stack.store.sessions.isEmpty, "genuine launch failure must not leave a ghost row")
        XCTAssertNil(stack.store.selectedSessionID)
        assertSourceMetadataAbsent(from: stack)
    }

    func testSuccessfulRetryAfterLauncherFailureClearsErrorAndThenLearns() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Home")
        stack.launcher.errorToThrow = SyntheticLaunchError()

        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)
        XCTAssertNotNil(stack.coordinator.lastFailureMessage)
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"))
        XCTAssertTrue(stack.store.sessions.isEmpty)

        stack.launcher.errorToThrow = nil
        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-456", title: nil, url: nil)

        XCTAssertNil(stack.coordinator.lastFailureMessage)
        XCTAssertNotNil(stack.store.selectedSession)
        XCTAssertEqual(stack.store.sessions.count, 1)
        XCTAssertEqual(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"), stack.workspaces.workspaces.first?.id)
        XCTAssertEqual(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket), stack.workspaces.workspaces.first?.id)
    }

    func testRepeatedRetryAfterLauncherFailureCreatesAtMostOneSession() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Home")
        stack.launcher.errorToThrow = SyntheticLaunchError()

        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)
        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)
        XCTAssertTrue(stack.store.sessions.isEmpty)
        XCTAssertEqual(stack.coordinator.lastFailureMessage, "Synthetic launcher failed.")
        XCTAssertEqual(stack.coordinator.lastFailure?.offersSettingsRoute, true)

        stack.launcher.errorToThrow = nil
        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)

        XCTAssertEqual(stack.store.sessions.count, 1)
        XCTAssertNil(stack.coordinator.lastFailureMessage)
        XCTAssertNotNil(stack.store.selectedSession)
    }

    func testPluginAssemblyFailureStillLaunchesOneUninstrumentedSession() async throws {
        let stack = makeStack(pluginAssembler: FakeAssembler())
        try addWorkspace(stack, named: "Home")

        await stack.coordinator.beginJiraTicketLaunch(
            key: Sentinel.key,
            title: Sentinel.title,
            url: Sentinel.url
        )

        XCTAssertNil(
            stack.coordinator.lastFailureMessage,
            "plugin assembly is optional; item 10 launch errors stay reserved for genuine failures"
        )
        XCTAssertEqual(stack.store.sessions.count, 1)
        XCTAssertEqual(stack.launcher.launchCount, 1)

        let session = try XCTUnwrap(stack.store.selectedSession)
        XCTAssertEqual(session.name, Sentinel.key)
        XCTAssertEqual(session.activity, .starting)
        XCTAssertEqual(session.bridgeStatus, .unavailable)
        XCTAssertNotEqual(session.bridgeStatus, .active)
        XCTAssertEqual(
            session.instrumentationWarning,
            SessionCreationError.pluginAssemblyFailed.errorDescription
        )
        XCTAssertNil(stack.store.debugSessionToken(session.id))

        let args = stack.launcher.lastArguments ?? []
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--plugin-dir"))
        XCTAssertFalse(args.contains("--allowedTools"))
        XCTAssertFalse(args.contains("--name"))
        XCTAssertEqual(
            stack.store.submit(prompt: "hello from fallback", to: session.id),
            .rejected(.sessionNotAcceptingInput)
        )
        assertSourceMetadataAbsent(from: stack)
        XCTAssertEqual(
            stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "SYN"),
            stack.workspaces.workspaces.first?.id
        )
        XCTAssertEqual(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket), stack.workspaces.workspaces.first?.id)
    }

    func testCancelClearsPendingChoiceAndFailure() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Home")
        stack.workspaces.setDefault(id: nil)

        let unresolved = try await stack.coordinator.launch(draft: stack.coordinator.draft(
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
