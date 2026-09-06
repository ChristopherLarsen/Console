import SwiftTerm
import XCTest
@testable import Console

/// Chooser Start/retry/cancel behavior on a fake launcher: invalid folders
/// disable Start, failed Start keeps the pending draft, and routing is
/// learned only after a successful create.
@MainActor
final class SessionWorkspaceChooserTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var locatorDefaults: UserDefaults!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        suiteName = "SessionWorkspaceChooserTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        locatorDefaults = UserDefaults(suiteName: "SessionWorkspaceChooserLocator-\(UUID().uuidString)")!
        locatorDefaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)

        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chooser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName!)
        try? FileManager.default.removeItem(at: tmpRoot!)
    }

    private final class FakeLauncher: SessionProcessLaunching {
        var launchCount = 0
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

    private func jiraDraft(_ stack: Stack, key: String = "ENG-123") -> SessionDraft {
        stack.coordinator.draft(
            purpose: .existingTicket,
            source: .jira(key: key, title: "Keep locally", url: URL(string: "https://example.test/browse/\(key)"))
        )
    }

    private func presentChooser(_ stack: Stack, draft: SessionDraft) throws -> PendingWorkspaceChoice {
        stack.workspaces.setDefault(id: nil)
        let result = try stack.coordinator.launch(draft: draft)
        XCTAssertNil(result)
        return try XCTUnwrap(stack.coordinator.pendingChoice)
    }

    func testStartDisabledForNoSelectionAndNonGitReviewFolder() throws {
        let stack = makeStack()
        let plain = addWorkspace(stack, named: "PlainOnly")
        let repo = addWorkspace(stack, named: "Repo", gitRemote: "https://gitlab.com/grp/proj.git")
        stack.workspaces.setDefault(id: nil)

        let reviewDraft = stack.coordinator.draft(
            purpose: .review,
            source: .mergeRequest(
                iid: "42",
                title: "Keep locally",
                url: URL(string: "https://gitlab.com/other/project/-/merge_requests/42")!
            )
        )
        let choice = try presentChooser(stack, draft: reviewDraft)
        XCTAssertEqual(choice.purpose, .review)
        XCTAssertTrue(stack.coordinator.presentsChoiceSheet)

        XCTAssertFalse(stack.coordinator.canConfirmWorkspace(workspaceID: nil, purpose: .review))
        XCTAssertFalse(stack.coordinator.canConfirmWorkspace(workspaceID: plain.id, purpose: .review))
        XCTAssertTrue(
            stack.coordinator.workspaceBlockingReason(workspaceID: plain.id, purpose: .review)?
                .contains("Git") == true
        )
        XCTAssertTrue(stack.coordinator.canConfirmWorkspace(workspaceID: repo.id, purpose: .review))
        XCTAssertNil(stack.coordinator.workspaceBlockingReason(workspaceID: repo.id, purpose: .review))
    }

    func testDisappearingFolderDisablesStartAndKeepsDraft() throws {
        let stack = makeStack()
        let folder = addWorkspace(stack, named: "SoonGone")
        let choice = try presentChooser(stack, draft: jiraDraft(stack))
        XCTAssertEqual(choice.name, "ENG-123")
        XCTAssertTrue(stack.coordinator.canConfirmWorkspace(workspaceID: folder.id, purpose: .existingTicket))

        try FileManager.default.removeItem(at: folder.directoryURL)

        XCTAssertFalse(stack.coordinator.canConfirmWorkspace(workspaceID: folder.id, purpose: .existingTicket))
        XCTAssertTrue(
            stack.coordinator.workspaceBlockingReason(workspaceID: folder.id, purpose: .existingTicket)?
                .contains("no longer available") == true
        )
        XCTAssertThrowsError(try stack.coordinator.confirmWorkspaceChoice(workspaceID: folder.id)) { error in
            XCTAssertEqual(error as? SessionLaunchCoordinator.LaunchError, .workspaceUnavailable)
        }
        let retained = try XCTUnwrap(stack.coordinator.pendingChoice)
        XCTAssertEqual(retained.name, "ENG-123")
        XCTAssertEqual(retained.purpose, .existingTicket)
        XCTAssertEqual(retained.selectedWorkspaceID, folder.id)
        XCTAssertTrue(stack.coordinator.presentsChoiceSheet)
        XCTAssertNotNil(stack.coordinator.lastFailureMessage)
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket))
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"))
    }

    func testNonGitReviewConfirmKeepsDraftAndDoesNotLearn() throws {
        let stack = makeStack()
        let plain = addWorkspace(stack, named: "PlainOnly")
        let reviewDraft = stack.coordinator.draft(
            purpose: .review,
            source: .mergeRequest(
                iid: "42",
                title: "Keep locally",
                url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/42")!
            )
        )
        _ = try presentChooser(stack, draft: reviewDraft)

        XCTAssertThrowsError(try stack.coordinator.confirmWorkspaceChoice(workspaceID: plain.id)) { error in
            XCTAssertEqual(error as? SessionLaunchCoordinator.LaunchError, .workspaceNotAGitRepository)
        }
        XCTAssertEqual(stack.coordinator.pendingChoice?.name, "Review !42")
        XCTAssertEqual(stack.coordinator.pendingChoice?.selectedWorkspaceID, plain.id)
        XCTAssertTrue(stack.coordinator.lastFailureMessage?.contains("Git") == true)
        XCTAssertEqual(stack.coordinator.lastFailure?.offersSettingsRoute, true)
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .review))
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "gitlab.com/grp/proj"))
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testInjectedLauncherFailureOnConfirmRetainsDraftUntilCancel() throws {
        let stack = makeStack()
        let home = addWorkspace(stack, named: "Home")
        let choice = try presentChooser(stack, draft: jiraDraft(stack))
        XCTAssertEqual(choice.name, "ENG-123")
        stack.launcher.errorToThrow = SyntheticLaunchError()
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        XCTAssertThrowsError(try stack.coordinator.confirmWorkspaceChoice(workspaceID: home.id))
        XCTAssertEqual(stack.coordinator.lastFailureMessage, "Synthetic launcher failed.")
        XCTAssertEqual(stack.coordinator.pendingChoice?.name, "ENG-123")
        XCTAssertEqual(stack.coordinator.pendingChoice?.selectedWorkspaceID, home.id)
        XCTAssertTrue(stack.coordinator.presentsChoiceSheet)
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"))
        XCTAssertNil(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            sidebarBefore
        )

        stack.coordinator.cancelWorkspaceChoice()
        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertNil(stack.coordinator.lastFailureMessage)
        XCTAssertFalse(stack.coordinator.presentsChoiceSheet)
    }

    func testRetryAfterChooserLauncherFailureSucceedsAndLearns() throws {
        let stack = makeStack()
        let home = addWorkspace(stack, named: "Home")
        _ = try presentChooser(stack, draft: jiraDraft(stack))
        stack.launcher.errorToThrow = SyntheticLaunchError()

        XCTAssertThrowsError(try stack.coordinator.confirmWorkspaceChoice(workspaceID: home.id))
        XCTAssertEqual(stack.coordinator.pendingChoice?.name, "ENG-123")

        stack.launcher.errorToThrow = nil
        let sessionID = try XCTUnwrap(try stack.coordinator.confirmWorkspaceChoice(workspaceID: home.id))

        XCTAssertNil(stack.coordinator.pendingChoice)
        XCTAssertNil(stack.coordinator.lastFailureMessage)
        XCTAssertFalse(stack.coordinator.presentsChoiceSheet)
        XCTAssertNotNil(stack.store.session(withID: sessionID))
        XCTAssertEqual(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"), home.id)
        XCTAssertEqual(stack.workspaces.lastUsedWorkspaceID(for: .existingTicket), home.id)
    }

    func testMissingClaudeOnConfirmKeepsDraftAndOffersSettings() throws {
        locatorDefaults.removeObject(forKey: ClaudeExecutableLocator.settingsKey)
        let notFound = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [] },
            defaults: locatorDefaults
        )
        let stack = makeStack(locator: notFound)
        let home = addWorkspace(stack, named: "Home")
        _ = try presentChooser(stack, draft: jiraDraft(stack))

        XCTAssertThrowsError(try stack.coordinator.confirmWorkspaceChoice(workspaceID: home.id)) { error in
            XCTAssertEqual(error as? SessionCreationError, .claudeNotFound)
        }
        XCTAssertEqual(stack.coordinator.pendingChoice?.name, "ENG-123")
        XCTAssertTrue(stack.coordinator.lastFailureMessage?.contains("Claude") == true)
        XCTAssertEqual(stack.coordinator.lastFailure?.offersSettingsRoute, true)
        XCTAssertNil(stack.workspaces.associatedWorkspaceID(forRoutingIdentity: "ENG"))
        XCTAssertEqual(stack.launcher.launchCount, 0)
    }

    func testOpenSessionsSettingsHidesChooserWithoutDroppingDraft() throws {
        let stack = makeStack()
        addWorkspace(stack, named: "Home")
        _ = try presentChooser(stack, draft: jiraDraft(stack))
        let workspaceID = stack.workspaces.workspaces[0].id
        stack.coordinator.updatePendingWorkspaceSelection(workspaceID)

        stack.coordinator.openSessionsSettings()

        XCTAssertFalse(stack.coordinator.presentsChoiceSheet)
        XCTAssertEqual(stack.coordinator.pendingChoice?.name, "ENG-123")
        XCTAssertEqual(stack.coordinator.pendingChoice?.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            SidebarSelection.settings.rawValue
        )

        stack.coordinator.restoreChoiceSheetIfNeeded()
        XCTAssertTrue(stack.coordinator.presentsChoiceSheet)
        XCTAssertEqual(stack.coordinator.pendingChoice?.selectedWorkspaceID, workspaceID)
    }
}
