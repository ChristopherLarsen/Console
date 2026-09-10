import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class DeveloperActionTests: XCTestCase {

    private var tmpRoot: URL!
    private var workspaceDefaults: UserDefaults!
    private var workspaceSuite: String!
    private var profileDefaults: UserDefaults!
    private var profileSuite: String!
    private var sessionDefaults: UserDefaults!
    private var sessionSuite: String!
    private var opener: RecordingDeveloperWorkspaceOpener!
    private var runner: FakeDeveloperProcessRunner!
    private var parser: FakeDeveloperResultParser!
    private var coordinator: IOSBuildCoordinator!
    private var actionRunner: DeveloperActionRunner!
    private var store: SessionStore!
    private var workspaceStore: SessionWorkspaceStore!
    private var profileStore: IOSProjectProfileStore!
    private var layout: SessionWorkspaceLayoutController!
    private var launchCoordinator: SessionLaunchCoordinator!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 15
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("developer-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        workspaceSuite = "DeveloperActionWorkspace-\(UUID().uuidString)"
        workspaceDefaults = UserDefaults(suiteName: workspaceSuite)!
        workspaceDefaults.removePersistentDomain(forName: workspaceSuite)
        profileSuite = "DeveloperActionProfile-\(UUID().uuidString)"
        profileDefaults = UserDefaults(suiteName: profileSuite)!
        profileDefaults.removePersistentDomain(forName: profileSuite)
        sessionSuite = "DeveloperActionSession-\(UUID().uuidString)"
        sessionDefaults = UserDefaults(suiteName: sessionSuite)!
        sessionDefaults.removePersistentDomain(forName: sessionSuite)
        sessionDefaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)

        opener = RecordingDeveloperWorkspaceOpener()
        runner = FakeDeveloperProcessRunner()
        parser = FakeDeveloperResultParser()
        coordinator = IOSBuildCoordinator(
            processRunner: runner,
            resultParser: parser,
            resultsDirectory: tmpRoot
        )
        actionRunner = DeveloperActionRunner(
            opener: opener,
            bundleExists: { [weak self] url in
                self?.existingBundles.contains(url.path) == true
            }
        )
        store = SessionStore(
            launcher: FakeDeveloperSessionLauncher(),
            locator: ClaudeExecutableLocator(defaults: sessionDefaults)
        )
        workspaceStore = SessionWorkspaceStore(defaults: workspaceDefaults)
        profileStore = IOSProjectProfileStore(defaults: profileDefaults)
        layout = SessionWorkspaceLayoutController()
        launchCoordinator = SessionLaunchCoordinator(store: store, workspaceStore: workspaceStore)
    }

    override func tearDownWithError() throws {
        if let coordinator {
            for job in coordinator.jobs where !job.state.isTerminal {
                coordinator.cancel(job.id)
            }
        }
        runner?.releaseAll()
        actionRunner?.simulatorModel.cancel()
        if let workspaceSuite { workspaceDefaults?.removePersistentDomain(forName: workspaceSuite) }
        if let profileSuite { profileDefaults?.removePersistentDomain(forName: profileSuite) }
        if let sessionSuite { sessionDefaults?.removePersistentDomain(forName: sessionSuite) }
        try? FileManager.default.removeItem(at: tmpRoot)
        existingBundles = []
        coordinator = nil
        actionRunner = nil
        store = nil
        workspaceStore = nil
        profileStore = nil
    }

    private var existingBundles: Set<String> = []

    private func hosts() -> DeveloperActionHosts {
        DeveloperActionHosts(
            sessionStore: store,
            layout: layout,
            workspaceStore: workspaceStore,
            profileStore: profileStore,
            buildCoordinator: coordinator,
            launchCoordinator: launchCoordinator
        )
    }

    // MARK: - Numbered shortcuts stay mapped

    func testNumberedNavigationShortcutsKeepTheirDestinations() {
        let expected: [SidebarSelection] = [
            .home, .jira, .mergeRequests,
            .sessions, .commands, .brief,
            .aiProvider
        ]
        // ⌃1…⌃8 across the eight sidebar destinations.
        let hotkeyNumbers = [1, 2, 3, 4, 5, 6, 7, 8]
        for (index, destination) in expected.enumerated() {
            XCTAssertEqual(
                ConsoleNavigation.sidebarDestination(hotkeyNumber: hotkeyNumbers[index]),
                destination,
                "⌃\(hotkeyNumbers[index]) must keep targeting \(destination.label)"
            )
        }
        XCTAssertEqual(ConsoleNavigation.maxSessionHotkeyNumber, 9)
        XCTAssertNil(ConsoleNavigation.sidebarDestination(hotkeyNumber: 10))
        XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: 1, in: []))
    }

    // MARK: - Availability

    func testBuildAndTestUnavailableWithoutProfileExplainWhy() {
        let snapshot = DeveloperActionSnapshot.empty
        let build = DeveloperActionCatalog.item(for: .buildSelectedProfile, in: snapshot)
        let tests = DeveloperActionCatalog.item(for: .runSelectedTests, in: snapshot)

        XCTAssertFalse(build.isEnabled)
        XCTAssertEqual(build.disabledReason, IOSBuildRequestError.missingProject.errorDescription)
        XCTAssertEqual(build.preview.summary, build.disabledReason)
        if case .unavailable(let reason) = build.route {
            XCTAssertEqual(reason, build.disabledReason)
        } else {
            XCTFail("Build should be unavailable")
        }

        XCTAssertFalse(tests.isEnabled)
        XCTAssertEqual(tests.disabledReason, IOSBuildRequestError.missingProject.errorDescription)
    }

    func testBuildUnavailableWithoutSchemeAndTestUnavailableWithoutPlan() {
        let workspace = SessionWorkspace(name: "App", directoryPath: "/tmp/App")
        let incomplete = DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: nil,
            hasSelectedSession: false,
            selectedSessionDirectory: nil,
            isFocusMode: false,
            workspaces: [workspace],
            defaultWorkspaceID: workspace.id,
            profiles: [
                workspace.id: IOSProjectProfile(
                    workspaceID: workspace.id,
                    projectPath: "/tmp/App.xcodeproj",
                    scheme: nil,
                    simulatorUDID: "SIM-1"
                )
            ],
            jobs: [],
            devices: [],
            isSimulatorInstalling: false,
            bundleExists: { _ in false }
        )
        let build = DeveloperActionCatalog.item(for: .buildSelectedProfile, in: incomplete)
        XCTAssertFalse(build.isEnabled)
        XCTAssertEqual(build.disabledReason, IOSBuildRequestError.missingScheme.errorDescription)

        let noPlan = DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: nil,
            hasSelectedSession: false,
            selectedSessionDirectory: nil,
            isFocusMode: false,
            workspaces: [workspace],
            defaultWorkspaceID: workspace.id,
            profiles: [workspace.id: validProfile(workspaceID: workspace.id, testPlan: nil)],
            jobs: [],
            devices: [sampleDevice()],
            isSimulatorInstalling: false,
            bundleExists: { _ in false }
        )
        let tests = DeveloperActionCatalog.item(for: .runSelectedTests, in: noPlan)
        XCTAssertFalse(tests.isEnabled)
        XCTAssertEqual(tests.disabledReason, IOSBuildRequestError.missingTestSelection.errorDescription)
        XCTAssertTrue(tests.preview.lines.contains { $0.contains("test plan") || $0.contains("UI suite") })
    }

    func testFocusAndNewSessionAndSimulatorReasons() {
        let empty = DeveloperActionSnapshot.empty
        XCTAssertEqual(
            DeveloperActionCatalog.item(for: .focusCurrentSession, in: empty).disabledReason,
            "Select a session before focusing."
        )
        XCTAssertEqual(
            DeveloperActionCatalog.item(for: .newGeneralSession, in: empty).disabledReason,
            "Choose a Session Folder in Settings → Claude."
        )
        XCTAssertEqual(
            DeveloperActionCatalog.item(for: .openWorkspaceInXcode, in: empty).disabledReason,
            "Choose an Xcode project in the selected workspace's iOS profile."
        )
        XCTAssertEqual(
            DeveloperActionCatalog.item(for: .openLatestResult, in: empty).disabledReason,
            "No local result bundle to open yet."
        )
        XCTAssertEqual(
            DeveloperActionCatalog.item(for: .runInSelectedSimulator, in: empty).disabledReason,
            "Select a successful build before installing."
        )

        let installing = validSnapshot().with(isSimulatorInstalling: true, succeededJobID: UUID())
        XCTAssertEqual(
            DeveloperActionCatalog.item(for: .runInSelectedSimulator, in: installing).disabledReason,
            "A Simulator install is already running."
        )
    }

    func testValidProfileEnablesBuildTestAndOpenXcode() {
        let snapshot = validSnapshot()
        XCTAssertTrue(DeveloperActionCatalog.item(for: .buildSelectedProfile, in: snapshot).isEnabled)
        XCTAssertTrue(DeveloperActionCatalog.item(for: .runSelectedTests, in: snapshot).isEnabled)
        XCTAssertTrue(DeveloperActionCatalog.item(for: .openWorkspaceInXcode, in: snapshot).isEnabled)
        XCTAssertTrue(DeveloperActionCatalog.item(for: .newGeneralSession, in: snapshot).isEnabled)
        XCTAssertFalse(DeveloperActionCatalog.item(for: .focusCurrentSession, in: snapshot).isEnabled)
    }

    // MARK: - Preview matches routed profile

    func testPreviewProfileMatchesBuildAndTestRoutes() {
        let profile = validProfile(workspaceID: UUID(), scheme: "ConsoleApp", testPlan: "Unit")
        let snapshot = validSnapshot(profile: profile, workspaceName: "Mobile")
        let build = DeveloperActionCatalog.item(for: .buildSelectedProfile, in: snapshot)
        let tests = DeveloperActionCatalog.item(for: .runSelectedTests, in: snapshot)

        XCTAssertEqual(build.preview.profile, snapshot.profile)
        XCTAssertEqual(build.preview.scheme, "ConsoleApp")
        XCTAssertEqual(build.preview.workspaceName, "Mobile")
        XCTAssertEqual(build.preview.deviceName, "iPhone 16 · iOS 18.4")
        XCTAssertEqual(build.preview.projectName, "App.xcodeproj")
        XCTAssertTrue(build.preview.summary.contains("ConsoleApp"))
        if case .submitBuild(let routed) = build.route {
            XCTAssertEqual(routed, build.preview.profile)
            XCTAssertEqual(routed.scheme, "ConsoleApp")
        } else {
            XCTFail("Expected submitBuild route")
        }

        if case .submitSelectedTests(let routed) = tests.route {
            XCTAssertEqual(routed, tests.preview.profile)
            XCTAssertEqual(routed.testPlan, "Unit")
        } else {
            XCTFail("Expected submitSelectedTests route")
        }
    }

    func testSimulatorRouteUsesPreviewDeviceAndProfile() {
        let jobID = UUID()
        let snapshot = validSnapshot().with(succeededJobID: jobID)
        let item = DeveloperActionCatalog.item(for: .runInSelectedSimulator, in: snapshot)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.preview.deviceName, snapshot.simulatorName)
        if case .installAndLaunch(let routedJob, let udid, let profile) = item.route {
            XCTAssertEqual(routedJob, jobID)
            XCTAssertEqual(udid, snapshot.profile?.simulatorUDID)
            XCTAssertEqual(profile, item.preview.profile)
        } else {
            XCTFail("Expected installAndLaunch")
        }
    }

    func testSessionDirectorySelectsWorkspaceForPreview() {
        let other = SessionWorkspace(name: "Other", directoryPath: "/tmp/other")
        let current = SessionWorkspace(name: "Current", directoryPath: "/tmp/current")
        let snapshot = DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: "General",
            hasSelectedSession: true,
            selectedSessionDirectory: URL(fileURLWithPath: "/tmp/current/src", isDirectory: true),
            isFocusMode: false,
            workspaces: [other, current],
            defaultWorkspaceID: other.id,
            profiles: [
                other.id: validProfile(workspaceID: other.id, scheme: "Other"),
                current.id: validProfile(workspaceID: current.id, scheme: "Current")
            ],
            jobs: [],
            devices: [sampleDevice()],
            isSimulatorInstalling: false,
            bundleExists: { _ in false }
        )
        XCTAssertEqual(snapshot.workspaceName, "Current")
        XCTAssertEqual(snapshot.profile?.scheme, "Current")
        let item = DeveloperActionCatalog.item(for: .buildSelectedProfile, in: snapshot)
        XCTAssertEqual(item.preview.scheme, "Current")
        if case .submitBuild(let profile) = item.route {
            XCTAssertEqual(profile.scheme, "Current")
        } else {
            XCTFail("Expected build of the session workspace profile")
        }
    }

    func testNestedChildWorkspaceWinsSessionResolution() {
        // A session living inside a registered child workspace must resolve
        // to the child, never to the containing parent (most specific root).
        let parent = SessionWorkspace(name: "Mono", directoryPath: "/tmp/mono")
        let child = SessionWorkspace(name: "App", directoryPath: "/tmp/mono/App")

        let resolved = DeveloperActionCatalog.resolvedWorkspace(
            selectedSessionDirectory: URL(fileURLWithPath: "/tmp/mono/App/Sources", isDirectory: true),
            workspaces: [parent, child],
            defaultWorkspaceID: parent.id
        )

        XCTAssertEqual(resolved?.id, child.id)
        XCTAssertEqual(resolved?.name, "App")

        // Parent still resolves when the session sits directly in it.
        let direct = DeveloperActionCatalog.resolvedWorkspace(
            selectedSessionDirectory: URL(fileURLWithPath: "/tmp/mono", isDirectory: true),
            workspaces: [parent, child],
            defaultWorkspaceID: nil
        )
        XCTAssertEqual(direct?.id, parent.id)
    }

    // MARK: - Search is memory-only

    func testSearchFilterIsStatelessAndDoesNotPersist() {
        let items = DeveloperActionCatalog.items(in: validSnapshot())
        let filtered = DeveloperActionCatalog.matching(items, query: "  Build  ")
        XCTAssertEqual(filtered.map(\.id), [.buildSelectedProfile])

        let byScheme = DeveloperActionCatalog.matching(items, query: "App")
        XCTAssertTrue(byScheme.contains(where: { $0.id == .buildSelectedProfile }))

        let reset = DeveloperActionCatalog.matching(items, query: "")
        XCTAssertEqual(reset.map(\.id), DeveloperActionID.allCases)

        let suite = "DeveloperActionSearch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        _ = DeveloperActionCatalog.matching(items, query: "Build Selected Profile")
        XCTAssertNil(defaults.object(forKey: "developerActions.search"))
        XCTAssertNil(defaults.object(forKey: "developerActions.history"))
        XCTAssertNil(defaults.stringArray(forKey: "DeveloperActions.SearchHistory"))
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Routing through coordinators

    func testExecutedBuildProfileMatchesPreviewAfterSettingsChange() async throws {
        let workspace = addWorkspace("Mobile")
        let original = validProfile(workspaceID: workspace.id, scheme: "App")
        profileStore.save(original)

        let snapshot = actionRunner.snapshot(hosts: hosts())
        let preview = DeveloperActionCatalog.item(for: .buildSelectedProfile, in: snapshot)
        XCTAssertEqual(preview.preview.profile?.scheme, "App")

        var mutated = original
        mutated.scheme = "Other"
        profileStore.save(mutated)

        runner.hold = true
        await actionRunner.perform(.buildSelectedProfile, snapshot: snapshot, hosts: hosts())

        XCTAssertEqual(actionRunner.lastExecutedProfile?.scheme, "App")
        XCTAssertEqual(coordinator.jobs.last?.profile.scheme, "App")
        XCTAssertNotEqual(profileStore.profile(for: workspace.id)?.scheme, coordinator.jobs.last?.profile.scheme)
        if case .submitBuild(let routed) = actionRunner.lastRoute {
            XCTAssertEqual(routed, preview.preview.profile)
        } else {
            XCTFail("Expected submitBuild")
        }
        if let id = coordinator.jobs.last?.id {
            coordinator.cancel(id)
            _ = try await waitForJob(id)
        }
    }

    func testRepeatedBuildObeysJobConcurrencyQueue() async throws {
        let workspace = addWorkspace("Mobile")
        profileStore.save(validProfile(workspaceID: workspace.id))
        let snapshot = actionRunner.snapshot(hosts: hosts())
        XCTAssertTrue(DeveloperActionCatalog.item(for: .buildSelectedProfile, in: snapshot).isEnabled)

        runner.hold = true
        await actionRunner.perform(.buildSelectedProfile, snapshot: snapshot, hosts: hosts())
        await actionRunner.perform(.buildSelectedProfile, snapshot: snapshot, hosts: hosts())

        XCTAssertEqual(coordinator.jobs.count, 2)
        let first = coordinator.jobs[0]
        let second = coordinator.jobs[1]
        try await waitUntil { self.coordinator.job(id: first.id)?.state == .running }
        XCTAssertEqual(coordinator.job(id: first.id)?.state, .running)
        XCTAssertEqual(coordinator.job(id: second.id)?.state, .queued)
        XCTAssertEqual(runner.invocations.count, 1)

        runner.releaseOne()
        _ = try await waitForJob(first.id)
        try await waitUntil { self.coordinator.job(id: second.id)?.state == .running }
        XCTAssertEqual(coordinator.job(id: second.id)?.state, .running)
        runner.releaseOne()
        _ = try await waitForJob(second.id)
    }

    func testUnavailableBuildDoesNotEnqueueAJob() async {
        await actionRunner.perform(
            .buildSelectedProfile,
            snapshot: .empty,
            hosts: hosts()
        )
        XCTAssertTrue(coordinator.jobs.isEmpty)
        XCTAssertEqual(actionRunner.lastActionMessage, IOSBuildRequestError.missingProject.errorDescription)
        if case .unavailable = actionRunner.lastRoute {
            // expected
        } else {
            XCTFail("Unavailable snapshot must not submit")
        }
    }

    /// A stale failure from a previous picker session must not greet the
    /// next ⌘⇧K presentation.
    func testPresentingPickerClearsStaleFailureMessage() async {
        await actionRunner.perform(.buildSelectedProfile, snapshot: .empty, hosts: hosts())
        XCTAssertNotNil(actionRunner.lastActionMessage)

        actionRunner.presentPicker()

        XCTAssertNil(actionRunner.lastActionMessage, "Reopening the picker starts fresh")
        actionRunner.dismissPicker()
    }

    func testOpenWorkspaceAndLatestResultUseOpener() async {
        let workspace = addWorkspace("Mobile")
        let profile = validProfile(workspaceID: workspace.id)
        profileStore.save(profile)
        let bundle = tmpRoot.appendingPathComponent("latest.xcresult")
        existingBundles.insert(bundle.path)
        var job = IOSBuildJob.queued(
            id: UUID(),
            kind: .build,
            profile: profile,
            testSelection: nil,
            resultBundleURL: bundle,
            createdAt: Date()
        )
        job.state = .succeeded
        // Snapshot capture reads coordinator.jobs; plant via submit is heavier,
        // so assert catalog routing and opener through perform with a crafted snapshot.
        var snapshot = actionRunner.snapshot(hosts: hosts())
        snapshot.latestResultURL = bundle
        snapshot.profile = profile

        await actionRunner.perform(.openWorkspaceInXcode, snapshot: snapshot, hosts: hosts())
        await actionRunner.perform(.openLatestResult, snapshot: snapshot, hosts: hosts())

        XCTAssertEqual(
            opener.opened.map(\.path),
            [
                URL(fileURLWithPath: profile.projectPath!).path,
                bundle.path
            ]
        )
    }

    func testFixedActionSetOrder() {
        XCTAssertEqual(
            DeveloperActionID.allCases,
            [
                .focusCurrentSession,
                .newGeneralSession,
                .openWorkspaceInXcode,
                .buildSelectedProfile,
                .runSelectedTests,
                .openLatestResult,
                .runInSelectedSimulator
            ]
        )
    }

    func testFocusRouteTogglesLayout() async {
        var snapshot = DeveloperActionSnapshot.empty
        snapshot.hasSelectedSession = true
        snapshot.selectedSessionName = "General"
        XCTAssertFalse(layout.isFocusMode)
        await actionRunner.perform(.focusCurrentSession, snapshot: snapshot, hosts: hosts())
        XCTAssertTrue(layout.isFocusMode)
        await actionRunner.perform(.focusCurrentSession, snapshot: snapshot, hosts: hosts())
        XCTAssertFalse(layout.isFocusMode)
    }

    // MARK: - Helpers

    @discardableResult
    private func addWorkspace(_ name: String) -> SessionWorkspace {
        let directory = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspaceStore.setDefaultFolderPath(directory.path)
        return workspaceStore.defaultFolder!
    }

    private func validProfile(
        workspaceID: UUID,
        scheme: String = "App",
        testPlan: String? = "Unit"
    ) -> IOSProjectProfile {
        IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: "/tmp/App.xcodeproj",
            scheme: scheme,
            configuration: "Debug",
            testPlan: testPlan,
            simulatorUDID: "SIM-1"
        )
    }

    private func sampleDevice() -> SimulatorDevice {
        SimulatorDevice(
            udid: "SIM-1",
            name: "iPhone 16",
            state: .shutdown,
            isAvailable: true,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
            runtimeName: "iOS 18.4",
            availabilityError: nil
        )
    }

    private func validSnapshot(
        profile: IOSProjectProfile? = nil,
        workspaceName: String = "Mobile"
    ) -> DeveloperActionSnapshot {
        let workspaceID = profile?.workspaceID ?? UUID()
        let workspace = SessionWorkspace(
            id: workspaceID,
            name: workspaceName,
            directoryPath: "/tmp/\(workspaceName)"
        )
        let saved = (profile ?? validProfile(workspaceID: workspaceID)).normalized()
        return DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: nil,
            hasSelectedSession: false,
            selectedSessionDirectory: nil,
            isFocusMode: false,
            workspaces: [workspace],
            defaultWorkspaceID: workspace.id,
            profiles: [workspace.id: saved],
            jobs: [],
            devices: [sampleDevice()],
            isSimulatorInstalling: false,
            bundleExists: { _ in false }
        )
    }

    // MARK: - Simulator route workspace scoping

    func testSimulatorRouteOnlyConsidersSucceededJobsInTheSelectedWorkspace() {
        let workspaceA = SessionWorkspace(id: UUID(), name: "Alpha", directoryPath: "/tmp/Alpha")
        let workspaceB = SessionWorkspace(id: UUID(), name: "Beta", directoryPath: "/tmp/Beta")
        var otherJob = IOSBuildJob.queued(
            id: UUID(),
            kind: .build,
            profile: validProfile(workspaceID: workspaceB.id).normalized(),
            testSelection: nil,
            resultBundleURL: URL(fileURLWithPath: "/tmp/Beta/b.xcresult"),
            createdAt: Date()
        )
        otherJob.state = .succeeded

        let foreignSnapshot = DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: nil,
            hasSelectedSession: false,
            selectedSessionDirectory: nil,
            isFocusMode: false,
            workspaces: [workspaceA, workspaceB],
            defaultWorkspaceID: workspaceA.id,
            profiles: [workspaceA.id: validProfile(workspaceID: workspaceA.id).normalized()],
            jobs: [otherJob],
            devices: [sampleDevice()],
            isSimulatorInstalling: false,
            bundleExists: { _ in false }
        )
        XCTAssertNil(foreignSnapshot.latestSucceededJobID)
        let foreignItem = DeveloperActionCatalog.item(for: .runInSelectedSimulator, in: foreignSnapshot)
        XCTAssertFalse(foreignItem.isEnabled)
        if case .unavailable = foreignItem.route {} else {
            XCTFail("expected unavailable route, got \(foreignItem.route)")
        }

        var ownJob = IOSBuildJob.queued(
            id: UUID(),
            kind: .build,
            profile: validProfile(workspaceID: workspaceA.id).normalized(),
            testSelection: nil,
            resultBundleURL: URL(fileURLWithPath: "/tmp/Alpha/a.xcresult"),
            createdAt: Date()
        )
        ownJob.state = .succeeded
        let ownSnapshot = DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: nil,
            hasSelectedSession: false,
            selectedSessionDirectory: nil,
            isFocusMode: false,
            workspaces: [workspaceA, workspaceB],
            defaultWorkspaceID: workspaceA.id,
            profiles: [workspaceA.id: validProfile(workspaceID: workspaceA.id).normalized()],
            jobs: [otherJob, ownJob],
            devices: [sampleDevice()],
            isSimulatorInstalling: false,
            bundleExists: { _ in false }
        )
        XCTAssertEqual(ownSnapshot.latestSucceededJobID, ownJob.id)
    }

    private func waitForJob(_ id: UUID, seconds: TimeInterval = 8) async throws -> IOSBuildJob {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let job = coordinator.job(id: id), job.state.isTerminal {
                return job
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout(seconds: seconds)
    }

    private func waitUntil(seconds: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout(seconds: seconds)
    }

    private struct TestTimeout: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Test exceeded \(seconds)s hard timeout" }
    }
}

private extension DeveloperActionSnapshot {
    func with(isSimulatorInstalling: Bool? = nil, succeededJobID: UUID? = nil) -> DeveloperActionSnapshot {
        var copy = self
        if let isSimulatorInstalling {
            copy.isSimulatorInstalling = isSimulatorInstalling
        }
        if let succeededJobID {
            copy.latestSucceededJobID = succeededJobID
        }
        return copy
    }
}

private final class FakeDeveloperSessionLauncher: SessionProcessLaunching {
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

private final class RecordingDeveloperWorkspaceOpener: IOSWorkspaceOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var openedStorage: [URL] = []
    var opened: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedStorage
    }

    func open(_ url: URL) {
        lock.lock()
        openedStorage.append(url)
        lock.unlock()
    }
}

private final class FakeDeveloperProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executablePath: String
        var arguments: [String]
        var workingDirectory: String?
    }

    private let lock = NSLock()
    private var invocationsStorage: [Invocation] = []
    private var releasedCount = 0
    private var stopHolds = false
    var hold = false

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocationsStorage
    }

    func releaseOne() {
        lock.lock()
        releasedCount += 1
        lock.unlock()
    }

    func releaseAll() {
        lock.lock()
        stopHolds = true
        releasedCount += 8
        lock.unlock()
    }

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        lock.lock()
        invocationsStorage.append(
            Invocation(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        )
        let shouldHold = hold
        lock.unlock()

        if shouldHold {
            let holdDeadline = Date().addingTimeInterval(8)
            var released = false
            while Date() < holdDeadline {
                if Task.isCancelled { throw ProcessRunError.cancelled }
                lock.lock()
                let stopped = stopHolds
                if releasedCount > 0 {
                    releasedCount -= 1
                    released = true
                }
                lock.unlock()
                if stopped { throw ProcessRunError.cancelled }
                if released { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if Task.isCancelled { throw ProcessRunError.cancelled }
            if !released { throw ProcessRunError.timedOut }
        }
        return ProcessResult(exitCode: 0, standardOutput: "BUILD SUCCEEDED", standardError: "")
    }
}

private final class FakeDeveloperResultParser: IOSResultParsing, @unchecked Sendable {
    func parseBundle(at url: URL, jobKind: IOSBuildJobKind) async -> IOSResultSummary {
        .parsed(outcome: .succeeded, issues: [])
    }
}
