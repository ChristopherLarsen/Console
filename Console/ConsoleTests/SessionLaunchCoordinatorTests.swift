import SwiftTerm
import XCTest
@testable import Console

/// End-to-end coordinator behavior on top of a fake launcher: typed requests,
/// single Session Folder validation, and proof that WebView-derived source
/// metadata never reaches Claude.
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

        func startExitShell(
            workingDirectory: String,
            environment: [String: String],
            terminalView: LocalProcessTerminalView
        ) {}
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
        stack.workspaces.setDefaultFolderPath(directory.path)
        return try XCTUnwrap(stack.workspaces.defaultFolder)
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

    // MARK: - Session Folder resolution

    func testUnsetSessionFolderThrowsActionableError() async throws {
        let stack = makeStack()

        do {
            _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(
                purpose: .newTicket,
                source: nil
            ))
            XCTFail("expected unset Session Folder to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .sessionFolderMissing)
            XCTAssertTrue(error.errorDescription?.contains("Settings") == true)
        }
        XCTAssertEqual(stack.launcher.launchCount, 0)
        XCTAssertTrue(stack.store.sessions.isEmpty)
    }

    func testContextualLaunchWithUnsetFolderSurfacesFailureWithSettingsRoute() async throws {
        let stack = makeStack()
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)

        XCTAssertEqual(
            stack.coordinator.lastFailureMessage,
            SessionLaunchCoordinator.LaunchError.sessionFolderMissing.errorDescription
        )
        XCTAssertEqual(stack.coordinator.lastFailure?.offersSettingsRoute, true)
        XCTAssertEqual(stack.launcher.launchCount, 0)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            sidebarBefore,
            "failed contextual launches must not navigate as if successful"
        )
    }

    func testEveryLaunchStartsInTheConfiguredSessionFolder() async throws {
        let stack = makeStack()
        let folder = try addWorkspace(stack, named: "Home")

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(purpose: .newTicket, source: nil))

        XCTAssertEqual(
            stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path,
            folder.directoryURL.standardizedFileURL.path
        )
    }

    func testUnavailableSessionFolderThrowsActionableError() async throws {
        let stack = makeStack()
        let folder = try addWorkspace(stack, named: "Vanished")
        try FileManager.default.removeItem(at: folder.directoryURL)

        do {
            _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .newTicket, source: nil))
            XCTFail("expected disappearing Session Folder to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .sessionFolderUnavailable)
            XCTAssertTrue(error.errorDescription?.contains("Settings") == true)
        }
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testNonGitSessionFolderThrowsActionableErrorForReviews() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "PlainOnly")

        do {
            _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(
                purpose: .review,
                source: mrSource("7")
            ))
            XCTFail("expected non-git review folder to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .sessionFolderNotAGitRepository)
        }
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testGeneralLaunchWorksInNonGitSessionFolder() async throws {
        let stack = makeStack()
        let folder = try addWorkspace(stack, named: "PlainOnly")

        let id = try await requireLaunch(stack, draft: stack.coordinator.draft(purpose: .general, source: nil))

        XCTAssertEqual(
            stack.store.session(withID: id)?.workingDirectory.standardizedFileURL.path,
            folder.directoryURL.standardizedFileURL.path
        )
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

    func testDisplayNameOverrideNamesSessionButKeepsSourceArtifactKey() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "NewTicketHome")

        await stack.coordinator.beginJiraTicketLaunch(
            key: "NMA-1234",
            title: nil,
            url: nil,
            displayName: NewTicketSessionNaming.displayName(forJiraKey: "NMA-1234")
        )

        let session = try XCTUnwrap(stack.store.selectedSession)
        XCTAssertEqual(session.name, "S-1234", "new-ticket launches render the story number as S-XXXX")
        XCTAssertTrue(
            session.artifacts.contains { $0.label == "NMA-1234" && $0.kind == .jiraIssue },
            "the seeded Jira artifact keeps the full key so Home story matching still resolves"
        )

        receiveLifecycleEvent(stack, sessionID: session.id, event: .sessionStarted, eventID: "evt-new-ticket-name")
        XCTAssertEqual(stack.store.session(withID: session.id)?.activity, .idle)
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
        XCTAssertEqual(stack.launcher.launchCount, 0)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            sidebarBefore,
            "failed contextual launches must not navigate as if successful"
        )
    }

    func testDisappearingFolderOverrideThrowsActionableError() async throws {
        let stack = makeStack()
        let folder = try addWorkspace(stack, named: "Vanished")
        try FileManager.default.removeItem(at: folder.directoryURL)

        do {
            _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(purpose: .general, source: nil))
            XCTFail("expected disappearing folder to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .sessionFolderUnavailable)
            XCTAssertTrue(error.errorDescription?.contains("Settings") == true)
        }
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testNonGitReviewOverrideThrowsActionableError() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "PlainOnly")

        do {
            _ = try await stack.coordinator.launch(draft: stack.coordinator.draft(
                purpose: .review,
                source: mrSource("7")
            ))
            XCTFail("expected non-git review folder to throw")
        } catch let error as SessionLaunchCoordinator.LaunchError {
            XCTAssertEqual(error, .sessionFolderNotAGitRepository)
        }
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
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            sidebarBefore
        )
        XCTAssertTrue(stack.store.sessions.isEmpty, "genuine launch failure must not leave a ghost row")
        XCTAssertNil(stack.store.selectedSessionID)
        assertSourceMetadataAbsent(from: stack)
    }

    func testSuccessfulRetryAfterLauncherFailureClearsErrorAndLaunches() async throws {
        let stack = makeStack()
        try addWorkspace(stack, named: "Home")
        stack.launcher.errorToThrow = SyntheticLaunchError()

        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-123", title: nil, url: nil)
        XCTAssertNotNil(stack.coordinator.lastFailureMessage)
        XCTAssertTrue(stack.store.sessions.isEmpty)

        stack.launcher.errorToThrow = nil
        await stack.coordinator.beginJiraTicketLaunch(key: "ENG-456", title: nil, url: nil)

        XCTAssertNil(stack.coordinator.lastFailureMessage)
        XCTAssertNotNil(stack.store.selectedSession)
        XCTAssertEqual(stack.store.sessions.count, 1)
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
    }
}
