import XCTest
@testable import Console

@MainActor
final class IOSProjectProfileStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "IOSProjectProfileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> IOSProjectProfileStore {
        IOSProjectProfileStore(defaults: defaults)
    }

    func testRoundTripPersistsOnlyLocalConfiguration() throws {
        let workspaceID = UUID()
        let profile = IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: "/tmp/My App/App.xcworkspace",
            scheme: "App",
            configuration: "Debug",
            testPlan: "Unit",
            simulatorUDID: "11111111-1111-1111-1111-111111111111"
        )
        let store = makeStore()
        store.save(profile)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profile(for: workspaceID), profile)

        let data = try XCTUnwrap(defaults.data(forKey: IOSProjectProfileStore.storageKey))
        let payload = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(payload.contains("CODE_SIGN"))
        XCTAssertFalse(payload.contains("PROVISIONING"))
        XCTAssertFalse(payload.contains("source"))
        XCTAssertTrue(payload.contains("workspaceID"))
        XCTAssertTrue(payload.contains("simulatorUDID"))
    }

    func testLegacyArrayPayloadMigrates() throws {
        let workspaceID = UUID()
        let legacy = [
            IOSProjectProfile(
                workspaceID: workspaceID,
                projectPath: "/tmp/App.xcodeproj",
                scheme: "App"
            )
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: IOSProjectProfileStore.storageKey)

        let store = makeStore()
        XCTAssertEqual(store.profile(for: workspaceID)?.scheme, "App")
        XCTAssertNil(store.profile(for: workspaceID)?.testPlan)
        XCTAssertNil(store.profile(for: workspaceID)?.simulatorUDID)
    }

    func testMissingOptionalFieldsLoadAsNil() throws {
        let workspaceID = UUID()
        let partial = """
        {
          "schemaVersion": 1,
          "profiles": [
            {
              "workspaceID": "\(workspaceID.uuidString)",
              "projectPath": "/tmp/App.xcodeproj",
              "scheme": "App"
            }
          ]
        }
        """
        defaults.set(Data(partial.utf8), forKey: IOSProjectProfileStore.storageKey)

        let store = makeStore()
        let loaded = try XCTUnwrap(store.profile(for: workspaceID))
        XCTAssertEqual(loaded.scheme, "App")
        XCTAssertNil(loaded.configuration)
        XCTAssertNil(loaded.testPlan)
        XCTAssertNil(loaded.simulatorUDID)
    }

    func testUnknownKeysAreIgnored() throws {
        let workspaceID = UUID()
        let extra = """
        {
          "schemaVersion": 1,
          "profiles": [
            {
              "workspaceID": "\(workspaceID.uuidString)",
              "scheme": "App",
              "signingIdentity": "iPhone Developer",
              "sourceSnippet": "let secret = 1"
            }
          ]
        }
        """
        defaults.set(Data(extra.utf8), forKey: IOSProjectProfileStore.storageKey)

        let store = makeStore()
        let loaded = try XCTUnwrap(store.profile(for: workspaceID))
        XCTAssertEqual(loaded.scheme, "App")
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: IOSProjectProfileStore.storageKey)), as: UTF8.self)
        XCTAssertFalse(persisted.contains("signingIdentity"))
        XCTAssertFalse(persisted.contains("sourceSnippet"))
    }

    func testEmptyStringsNormalizeToNilOnSave() {
        let workspaceID = UUID()
        let store = makeStore()
        store.save(
            IOSProjectProfile(
                workspaceID: workspaceID,
                projectPath: "  ",
                scheme: "",
                configuration: "Debug"
            )
        )
        let loaded = store.profile(for: workspaceID)
        XCTAssertNil(loaded?.projectPath)
        XCTAssertNil(loaded?.scheme)
        XCTAssertEqual(loaded?.configuration, "Debug")
    }

    func testApplyRefreshDoesNotSaveWhenRepairIsUnchanged() throws {
        let workspaceID = UUID()
        let saved = IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: "/tmp/App.xcodeproj",
            scheme: "App",
            configuration: "Debug"
        )
        let store = makeStore()
        store.save(saved)
        let original = try XCTUnwrap(defaults.data(forKey: IOSProjectProfileStore.storageKey))

        let result = IOSDiscoveryRefreshResult(
            listing: nil,
            destinations: [],
            repair: IOSProfileRepair.Outcome(profile: .empty(workspaceID: workspaceID), issues: [], didChangeProfile: false),
            errorMessage: "xcodebuild timed out while reading the project."
        )
        store.applyRefresh(result)

        XCTAssertEqual(store.profile(for: workspaceID), saved)
        XCTAssertEqual(defaults.data(forKey: IOSProjectProfileStore.storageKey), original)
    }

    func testApplyRefreshSavesOnlyUnambiguousEmptyFieldFills() {
        let workspaceID = UUID()
        let store = makeStore()
        let filled = IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: "/tmp/App.xcodeproj",
            scheme: "App"
        )
        store.applyRefresh(
            IOSDiscoveryRefreshResult(
                listing: nil,
                destinations: [],
                repair: IOSProfileRepair.Outcome(profile: filled, issues: [], didChangeProfile: true),
                errorMessage: nil
            )
        )
        XCTAssertEqual(store.profile(for: workspaceID), filled)
    }

    func testCorruptPayloadDoesNotWipeLaterSaves() {
        defaults.set(Data("not-json".utf8), forKey: IOSProjectProfileStore.storageKey)
        let store = makeStore()
        XCTAssertTrue(store.profilesByWorkspaceID.isEmpty)

        let workspaceID = UUID()
        store.save(IOSProjectProfile(workspaceID: workspaceID, scheme: "App"))
        XCTAssertEqual(makeStore().profile(for: workspaceID)?.scheme, "App")
    }

    func testRemoveProfileAndRetainOnly() {
        let keep = UUID()
        let drop = UUID()
        let store = makeStore()
        store.save(IOSProjectProfile(workspaceID: keep, scheme: "Keep"))
        store.save(IOSProjectProfile(workspaceID: drop, scheme: "Drop"))

        store.removeProfile(for: drop)
        XCTAssertNil(store.profile(for: drop))
        XCTAssertEqual(store.profile(for: keep)?.scheme, "Keep")

        store.save(IOSProjectProfile(workspaceID: drop, scheme: "Drop"))
        store.retainOnly(workspaceIDs: [keep])
        XCTAssertNil(store.profile(for: drop))
        XCTAssertEqual(makeStore().profile(for: keep)?.scheme, "Keep")
    }
}

@MainActor
final class IOSProjectSettingsModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        suiteName = "IOSProjectSettingsModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    func testDiscoveryFailureLeavesPreviouslyValidProfileIntact() async throws {
        let projectURL = tmpRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let workspace = SessionWorkspace(name: "App", directoryPath: tmpRoot.path)
        let saved = IOSProjectProfile(
            workspaceID: workspace.id,
            projectPath: projectURL.path,
            scheme: "App",
            configuration: "Debug",
            testPlan: "Unit",
            simulatorUDID: "LIVE-UDID"
        )
        let store = IOSProjectProfileStore(defaults: defaults)
        store.save(saved)

        let runner = FailingListRunner()
        let model = IOSProjectSettingsModel(discovery: IOSProjectDiscovery(processRunner: runner))
        await model.refreshAndWait(workspace: workspace, store: store)

        XCTAssertEqual(store.profile(for: workspace.id), saved)
        XCTAssertNotNil(model.errorMessage)
    }

    func testEmptyProfileIsNeverAutoFilledAndFlagsProjectNotSelected() async throws {
        let projectURL = tmpRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let workspace = SessionWorkspace(name: "App", directoryPath: tmpRoot.path)
        let store = IOSProjectProfileStore(defaults: defaults)
        let runner = ListingRunner(listJSON: """
        {
          "project" : {
            "configurations" : [ "Debug" ],
            "name" : "App",
            "schemes" : [ "App" ],
            "targets" : [ "App" ]
          }
        }
        """)
        let model = IOSProjectSettingsModel(discovery: IOSProjectDiscovery(processRunner: runner))
        await model.refreshAndWait(workspace: workspace, store: store)

        XCTAssertNil(store.profile(for: workspace.id)?.projectPath, "the project is never chosen automatically")
        XCTAssertEqual(model.issues, [.projectNotSelected])
        XCTAssertNil(model.listing)
        XCTAssertFalse(model.destinationsLookupSucceeded)
    }

    func testRefreshClearsStaleOptionsWhileSearching() async throws {
        let projectURL = tmpRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let workspace = SessionWorkspace(name: "App", directoryPath: tmpRoot.path)
        let store = IOSProjectProfileStore(defaults: defaults)
        store.save(IOSProjectProfile(workspaceID: workspace.id, projectPath: projectURL.path, scheme: "App"))
        let runner = ScriptedSettingsRunner(listJSON: Self.singleOptionListJSON)
        runner.listDelaysFromSecondCall = 0.6
        let model = IOSProjectSettingsModel(discovery: IOSProjectDiscovery(processRunner: runner))

        await model.refreshAndWait(workspace: workspace, store: store)
        XCTAssertTrue(model.destinationsLookupSucceeded)

        let task = Task { await model.refreshAndWait(workspace: workspace, store: store) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.isDiscovering)
        XCTAssertNil(model.listing)
        XCTAssertTrue(model.destinations.isEmpty)
        XCTAssertFalse(model.destinationsLookupSucceeded)

        await task.value
        XCTAssertEqual(store.profile(for: workspace.id)?.projectPath, projectURL.standardizedFileURL.path)
    }

    func testMidRefreshProfileEditsSurviveRepairApply() async throws {
        let projectURL = tmpRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let workspace = SessionWorkspace(name: "App", directoryPath: tmpRoot.path)
        let store = IOSProjectProfileStore(defaults: defaults)
        store.save(IOSProjectProfile(workspaceID: workspace.id, projectPath: projectURL.path, scheme: "App"))
        let runner = ScriptedSettingsRunner(listJSON: Self.singleOptionListJSON)
        runner.listDelaysFromSecondCall = 0.6
        let model = IOSProjectSettingsModel(discovery: IOSProjectDiscovery(processRunner: runner))

        await model.refreshAndWait(workspace: workspace, store: store)

        runner.destinationJSON = Self.singleDestinationJSON
        let task = Task { await model.refreshAndWait(workspace: workspace, store: store) }
        try await Task.sleep(nanoseconds: 150_000_000)
        model.selectTestPlan("MyPlan", workspaceID: workspace.id, store: store)
        await task.value

        let loaded = try XCTUnwrap(store.profile(for: workspace.id))
        XCTAssertEqual(loaded.testPlan, "MyPlan")
        XCTAssertEqual(loaded.simulatorUDID, "NEW-UDID-1234")
    }

    func testFailedDestinationLookupKeepsSavedSimulatorWithoutUnavailableLabel() async throws {
        let projectURL = tmpRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let workspace = SessionWorkspace(name: "App", directoryPath: tmpRoot.path)
        let saved = IOSProjectProfile(
            workspaceID: workspace.id,
            projectPath: projectURL.path,
            scheme: "App",
            simulatorUDID: "LIVE-UDID"
        )
        let store = IOSProjectProfileStore(defaults: defaults)
        store.save(saved)

        let failing = ScriptedSettingsRunner(listJSON: Self.singleOptionListJSON)
        failing.destinationError = ProcessRunError.timedOut
        let model = IOSProjectSettingsModel(discovery: IOSProjectDiscovery(processRunner: failing))
        await model.refreshAndWait(workspace: workspace, store: store)

        XCTAssertFalse(model.destinationsLookupSucceeded)
        XCTAssertEqual(store.profile(for: workspace.id)?.simulatorUDID, "LIVE-UDID")
        XCTAssertFalse(
            model.issues.contains { if case .savedSimulatorMissing = $0 { return true }; return false }
        )
        XCTAssertNil(model.issues.first)

        let listing = ScriptedSettingsRunner(listJSON: Self.singleOptionListJSON)
        listing.destinationJSON = Self.knownDestinationJSON
        let confirming = IOSProjectSettingsModel(discovery: IOSProjectDiscovery(processRunner: listing))
        await confirming.refreshAndWait(workspace: workspace, store: store)
        XCTAssertTrue(confirming.destinationsLookupSucceeded)
        XCTAssertFalse(
            confirming.issues.contains { if case .savedSimulatorMissing = $0 { return true }; return false }
        )
    }

    private static let singleOptionListJSON = """
    {
      "project" : {
        "configurations" : [ "Debug" ],
        "name" : "App",
        "schemes" : [ "App" ],
        "targets" : [ "App" ]
      }
    }
    """

    private static let singleDestinationJSON = """
    {"destinations":[{"id":"NEW-UDID-1234","name":"iPhone 16","OS":"18.4","platform":"iOS Simulator"}]}
    """

    private static let knownDestinationJSON = """
    {"destinations":[{"id":"LIVE-UDID","name":"iPhone 16","OS":"18.4","platform":"iOS Simulator"}]}
    """
}

private final class FailingListRunner: ProcessRunning, @unchecked Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        _ = executablePath
        _ = arguments
        _ = workingDirectory
        _ = deadline
        throw ProcessRunError.timedOut
    }
}

private final class ListingRunner: ProcessRunning, @unchecked Sendable {
    let listJSON: String
    init(listJSON: String) { self.listJSON = listJSON }

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        _ = executablePath
        _ = workingDirectory
        _ = deadline
        if arguments.contains("-list") {
            return ProcessResult(exitCode: 0, standardOutput: listJSON, standardError: "")
        }
        if arguments.contains("-showTestPlans") {
            return ProcessResult(exitCode: 0, standardOutput: #"{"testPlans":[]}"#, standardError: "")
        }
        if arguments.contains("-showdestinations") {
            return ProcessResult(exitCode: 0, standardOutput: #"{"destinations":[]}"#, standardError: "")
        }
        return ProcessResult(exitCode: 1, standardOutput: "", standardError: "unexpected")
    }
}

private final class ScriptedSettingsRunner: ProcessRunning, @unchecked Sendable {
    let listJSON: String
    var destinationJSON = #"{"destinations":[]}"#
    var destinationError: Error?
    var listDelaysFromSecondCall: TimeInterval = 0

    private let lock = NSLock()
    private var listCalls = 0

    init(listJSON: String) {
        self.listJSON = listJSON
    }

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        _ = executablePath
        _ = workingDirectory
        _ = deadline
        if arguments.contains("-list") {
            lock.lock()
            listCalls += 1
            let call = listCalls
            lock.unlock()
            if call >= 2, listDelaysFromSecondCall > 0 {
                try? await Task.sleep(nanoseconds: UInt64(listDelaysFromSecondCall * 1_000_000_000))
            }
            return ProcessResult(exitCode: 0, standardOutput: listJSON, standardError: "")
        }
        if arguments.contains("-showTestPlans") {
            return ProcessResult(exitCode: 0, standardOutput: #"{"testPlans":[]}"#, standardError: "")
        }
        if arguments.contains("-showdestinations") {
            if let destinationError { throw destinationError }
            return ProcessResult(exitCode: 0, standardOutput: destinationJSON, standardError: "")
        }
        return ProcessResult(exitCode: 1, standardOutput: "", standardError: "unexpected")
    }
}
