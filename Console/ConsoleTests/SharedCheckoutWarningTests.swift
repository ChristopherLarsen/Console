import SwiftTerm
import XCTest
@testable import Console

/// Shared-checkout warning: canonical-path occupancy, fake Git state, and
/// Focus / Continue / Cancel without mutating the working copy.
@MainActor
final class SharedCheckoutWarningTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var locatorDefaults: UserDefaults!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        suiteName = "SharedCheckoutWarningTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        locatorDefaults = UserDefaults(suiteName: "SharedCheckoutWarningLocator-\(UUID().uuidString)")!
        locatorDefaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-checkout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName!)
        try? FileManager.default.removeItem(at: tmpRoot!)
    }

    // MARK: - Fakes

    private final class FakeLauncher: SessionProcessLaunching {
        var launchCount = 0

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
        }

        func startExitShell(
            workingDirectory: String,
            environment: [String: String],
            terminalView: LocalProcessTerminalView
        ) {}
    }

    private final class RecordingGitInspector: LocalGitInspecting, @unchecked Sendable {
        var defaultState: LocalGitWorkingCopyState
        var inspectPaths: [String] = []

        init(state: LocalGitWorkingCopyState = .fixture(branch: "review-branch", isDirty: true)) {
            self.defaultState = state
        }

        func inspect(canonicalPath: String) async -> LocalGitWorkingCopyState {
            inspectPaths.append(canonicalPath)
            return defaultState
        }
    }

    @MainActor
    private final class ParkingRecheckGate {
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var waitingForCount: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func pause() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                parked.append(cont)
                if let waiting = waitingForCount, parked.count >= waiting.count {
                    waitingForCount = nil
                    waiting.continuation.resume()
                }
            }
        }

        func waitUntilParked(count: Int) async {
            if parked.count >= count { return }
            await withCheckedContinuation { cont in
                if parked.count >= count {
                    cont.resume()
                } else {
                    waitingForCount = (count, cont)
                }
            }
        }

        func releaseAll() {
            let all = parked
            parked.removeAll()
            all.forEach { $0.resume() }
        }
    }

    private struct Stack {
        let store: SessionStore
        let workspaces: SessionWorkspaceStore
        let coordinator: SessionLaunchCoordinator
        let launcher: FakeLauncher
        let gitInspector: RecordingGitInspector
    }

    private func makeStack(
        gitInspector: RecordingGitInspector = RecordingGitInspector(),
        recheckGate: (@MainActor () async -> Void)? = nil
    ) -> Stack {
        let launcher = FakeLauncher()
        let store = SessionStore(
            launcher: launcher,
            locator: ClaudeExecutableLocator(defaults: locatorDefaults)
        )
        let workspaces = SessionWorkspaceStore(defaults: defaults!)
        let coordinator = SessionLaunchCoordinator(
            store: store,
            workspaceStore: workspaces,
            gitInspector: gitInspector,
            recheckGate: recheckGate
        )
        return Stack(
            store: store,
            workspaces: workspaces,
            coordinator: coordinator,
            launcher: launcher,
            gitInspector: gitInspector
        )
    }

    @discardableResult
    private func addWorkspace(_ stack: Stack, named name: String) throws -> SessionWorkspace {
        let directory = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return stack.workspaces.add(name: name, directoryURL: directory)
    }

    private func generalDraft(_ stack: Stack, workspaceID: UUID, name: String = "General") -> SessionDraft {
        var draft = stack.coordinator.draft(purpose: .general, source: nil)
        draft.name = name
        draft.workspaceID = workspaceID
        return draft
    }

    private struct GitFixtureError: Error {}

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=ConsoleFixture",
            "-c", "user.email=fixture@example.test",
        ] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_NAME"] = "ConsoleFixture"
        environment["GIT_AUTHOR_EMAIL"] = "fixture@example.test"
        environment["GIT_COMMITTER_NAME"] = "ConsoleFixture"
        environment["GIT_COMMITTER_EMAIL"] = "fixture@example.test"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitFixtureError() }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Path + porcelain

    func testCanonicalPathResolvesSymlinkAliases() throws {
        let real = tmpRoot.appendingPathComponent("RealCheckout", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = tmpRoot.appendingPathComponent("AliasCheckout")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        XCTAssertEqual(CheckoutPath.canonical(real), CheckoutPath.canonical(alias))
        XCTAssertEqual(
            CheckoutPath.canonical(real),
            CheckoutPath.canonical(URL(fileURLWithPath: real.path + "/", isDirectory: true))
        )
    }

    func testPorcelainParserReadsBranchDirtyAndDetached() {
        let clean = LocalGitWorkingCopyInspector.workingCopyState(fromPorcelainStatus: "## main\n")
        XCTAssertEqual(clean.branchName, "main")
        XCTAssertFalse(clean.isDirty)
        XCTAssertFalse(clean.isDetached)

        let dirty = LocalGitWorkingCopyInspector.workingCopyState(
            fromPorcelainStatus: "## feature...origin/feature [ahead 1]\n M file.swift\n?? new.txt\n"
        )
        XCTAssertEqual(dirty.branchName, "feature")
        XCTAssertTrue(dirty.isDirty)

        let detached = LocalGitWorkingCopyInspector.workingCopyState(fromPorcelainStatus: "## HEAD (no branch)\n")
        XCTAssertTrue(detached.isDetached)
        XCTAssertFalse(detached.isDirty)
        XCTAssertEqual(detached.branchDisplay, "Detached HEAD")

        let emptyRepo = LocalGitWorkingCopyInspector.workingCopyState(
            fromPorcelainStatus: "## No commits yet on main\n?? seed.txt\n"
        )
        XCTAssertEqual(emptyRepo.branchName, "main")
        XCTAssertTrue(emptyRepo.isDirty)
    }

    func testReviewPurposeIsClassifiedAsEditing() {
        for purpose in SessionPurpose.allCases {
            XCTAssertTrue(
                purpose.occupiesCheckoutForEditing,
                "\(purpose.rawValue) must be treated as editing; reviews are not assumed read-only"
            )
        }
    }

    // MARK: - Occupancy

    func testTwoEditingSessionsOnOneCanonicalDirectoryWarnAndDoNotLaunch() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "Home")
        let first = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "First"))
        XCTAssertNotNil(first)
        XCTAssertEqual(stack.launcher.launchCount, 1)

        let second = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Second"))
        XCTAssertNil(second, "second editing session must wait on the warning")
        XCTAssertEqual(stack.launcher.launchCount, 1)
        XCTAssertEqual(stack.store.sessions.count, 1)

        let warning = try XCTUnwrap(stack.coordinator.pendingCollision)
        XCTAssertTrue(stack.coordinator.presentsCollisionSheet)
        XCTAssertEqual(warning.gitState.branchName, "review-branch")
        XCTAssertTrue(warning.gitState.isDirty)
        XCTAssertEqual(warning.gitState.workingTreeDisplay, "Uncommitted local changes")
        XCTAssertEqual(warning.liveOccupants.map(\.name), ["First"])
        XCTAssertEqual(CheckoutPath.canonical(home.directoryURL), warning.canonicalPath)
        XCTAssertEqual(stack.gitInspector.inspectPaths, [warning.canonicalPath])
        XCTAssertTrue(warning.canFocusExisting)
    }

    func testSymbolicLinkAliasMatchesTheSameCheckout() async throws {
        let stack = makeStack()
        let real = try addWorkspace(stack, named: "RealCheckout")
        let aliasURL = tmpRoot.appendingPathComponent("AliasCheckout")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: real.directoryURL)
        let alias = stack.workspaces.add(name: "AliasCheckout", directoryURL: aliasURL)

        _ = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: real.id, name: "OnReal"))
        let second = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: alias.id, name: "OnAlias"))

        XCTAssertNil(second)
        XCTAssertEqual(stack.launcher.launchCount, 1)
        XCTAssertEqual(stack.coordinator.pendingCollision?.liveOccupants.map(\.name), ["OnReal"])
        XCTAssertEqual(
            stack.coordinator.pendingCollision?.canonicalPath,
            CheckoutPath.canonical(real.directoryURL)
        )
    }

    func testLinkedWorktreesAreDistinctCheckouts() async throws {
        let stack = makeStack()
        let main = tmpRoot.appendingPathComponent("MainCheckout", isDirectory: true)
        try runGit(["init", "-q"], in: main)
        try runGit(["commit", "--allow-empty", "-q", "-m", "init"], in: main)
        let linked = tmpRoot.appendingPathComponent("LinkedWorktree", isDirectory: true)
        try runGit(["worktree", "add", "--detach", "-q", linked.path], in: main)

        XCTAssertNotEqual(CheckoutPath.canonical(main), CheckoutPath.canonical(linked))

        let mainWorkspace = stack.workspaces.add(name: "Main", directoryURL: main)
        let linkedWorkspace = stack.workspaces.add(name: "Linked", directoryURL: linked)

        let first = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: mainWorkspace.id, name: "MainSession"))
        let second = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: linkedWorkspace.id, name: "LinkedSession"))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "linked worktrees share a repo but not a checkout")
        XCTAssertNil(stack.coordinator.pendingCollision)
        XCTAssertEqual(stack.launcher.launchCount, 2)
        XCTAssertEqual(stack.store.sessions.count, 2)
        XCTAssertTrue(stack.gitInspector.inspectPaths.isEmpty, "no collision means no Git inspect")
    }

    func testExitedSessionDoesNotBlockANewLaunch() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "Home")
        let firstLaunch = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Done"))
        let firstID = try XCTUnwrap(firstLaunch)
        stack.store.stopSession(id: firstID)
        XCTAssertEqual(stack.store.session(withID: firstID)?.activity, .exited)

        let second = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Next"))
        XCTAssertNotNil(second)
        XCTAssertNil(stack.coordinator.pendingCollision)
        XCTAssertEqual(stack.launcher.launchCount, 2)
    }

    func testReviewLaunchWarnsOnASharedCheckout() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "ReviewHome")
        try runGit(["init", "-q"], in: home.directoryURL)
        var first = stack.coordinator.draft(purpose: .review, source: nil)
        first.name = "Review A"
        first.workspaceID = home.id
        let firstID = try await stack.coordinator.launch(draft: first)
        XCTAssertNotNil(firstID)

        var second = stack.coordinator.draft(purpose: .review, source: nil)
        second.name = "Review B"
        second.workspaceID = home.id
        let result = try await stack.coordinator.launch(draft: second)

        XCTAssertNil(result, "reviews are classified as editing")
        XCTAssertEqual(stack.launcher.launchCount, 1)
        XCTAssertEqual(stack.coordinator.pendingCollision?.liveOccupants.first?.purpose, .review)
    }

    // MARK: - Actions

    func testFocusExistingSessionLaunchesNothing() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "Home")
        let firstLaunch = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Keep"))
        let firstID = try XCTUnwrap(firstLaunch)
        let sidebarBefore = UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey)

        _ = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Skip"))
        XCTAssertNotNil(stack.coordinator.pendingCollision)

        stack.store.select(sessionID: UUID())
        stack.coordinator.focusExistingSession()

        XCTAssertEqual(stack.store.selectedSessionID, firstID)
        XCTAssertEqual(stack.store.sessions.count, 1)
        XCTAssertEqual(stack.launcher.launchCount, 1)
        XCTAssertNil(stack.coordinator.pendingCollision)
        XCTAssertFalse(stack.coordinator.presentsCollisionSheet)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ConsoleNavigation.sidebarKey),
            SidebarSelection.sessions.rawValue
        )
        _ = sidebarBefore
    }

    func testContinueRequiresExplicitChoiceAndPreservesUncommittedFiles() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "DirtyHome")
        let dirtyFile = home.directoryURL.appendingPathComponent("uncommitted.txt")
        try "keep-me".write(to: dirtyFile, atomically: true, encoding: .utf8)

        _ = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "First"))
        let blocked = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Second"))
        XCTAssertNil(blocked)
        XCTAssertEqual(stack.launcher.launchCount, 1)

        let continued = try await stack.coordinator.continueInSameFolder()
        XCTAssertNotNil(continued)
        XCTAssertEqual(stack.store.sessions.count, 2)
        XCTAssertEqual(stack.launcher.launchCount, 2)
        XCTAssertNil(stack.coordinator.pendingCollision)
        XCTAssertEqual(try String(contentsOf: dirtyFile, encoding: .utf8), "keep-me")
        XCTAssertEqual(
            stack.gitInspector.inspectPaths.count,
            1,
            "Continue must not re-run Git and must never reset or stash"
        )
    }

    func testCancelLeavesTheExistingSessionAlone() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "Home")
        let firstLaunch = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id))
        let firstID = try XCTUnwrap(firstLaunch)
        _ = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Nope"))

        stack.coordinator.cancelSharedCheckoutWarning()

        XCTAssertNil(stack.coordinator.pendingCollision)
        XCTAssertEqual(stack.store.sessions.map(\.id), [firstID])
        XCTAssertEqual(stack.launcher.launchCount, 1)
    }

    func testPendingWarningBlocksAThirdLaunch() async throws {
        let stack = makeStack()
        let home = try addWorkspace(stack, named: "Home")
        _ = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "One"))
        _ = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Two"))
        XCTAssertNotNil(stack.coordinator.pendingCollision)

        let third = try await stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "Three"))
        XCTAssertNil(third)
        XCTAssertEqual(stack.store.sessions.count, 1)
        XCTAssertEqual(stack.launcher.launchCount, 1)
        XCTAssertNotNil(stack.coordinator.pendingCollision)
    }

    func testSimultaneousLaunchesRecheckClaimsBeforeCreate() async throws {
        let gate = ParkingRecheckGate()
        let inspector = RecordingGitInspector()
        let stack = makeStack(gitInspector: inspector, recheckGate: { await gate.pause() })
        let home = try addWorkspace(stack, named: "RaceHome")

        async let first = stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "RaceA"))
        async let second = stack.coordinator.launch(draft: generalDraft(stack, workspaceID: home.id, name: "RaceB"))
        await gate.waitUntilParked(count: 2)
        gate.releaseAll()
        let id1 = try await first
        let id2 = try await second

        XCTAssertNil(id1)
        XCTAssertNil(id2)
        XCTAssertEqual(stack.store.sessions.count, 0, "neither request may bypass the warning")
        XCTAssertEqual(stack.launcher.launchCount, 0)
        XCTAssertNotNil(stack.coordinator.pendingCollision)
    }

    func testStoreHelperIgnoresExitedSessionsAndMatchesCanonicalPaths() async throws {
        let stack = makeStack()
        let directory = tmpRoot.appendingPathComponent("StorePath", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alias = tmpRoot.appendingPathComponent("StoreAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)

        let liveID = try stack.store.createSession(name: "Live", workingDirectory: directory)
        let exitedID = try stack.store.createSession(name: "Gone", workingDirectory: directory)
        stack.store.stopSession(id: exitedID)

        let canonical = CheckoutPath.canonical(alias)
        let live = stack.store.liveEditingSessions(occupyingCanonicalPath: canonical)
        XCTAssertEqual(live.map(\.id), [liveID])
    }
}
