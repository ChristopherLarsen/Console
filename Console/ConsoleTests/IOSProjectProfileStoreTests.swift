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
            candidates: [],
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
                candidates: [IOSProjectCandidate(path: "/tmp/App.xcodeproj")!],
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
        XCTAssertEqual(model.candidates.count, 1)
    }

    func testUniqueProjectIsFilledWhenProfileIsEmpty() async throws {
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

        let loaded = try XCTUnwrap(store.profile(for: workspace.id))
        XCTAssertEqual(loaded.projectPath, projectURL.standardizedFileURL.path)
        XCTAssertEqual(loaded.scheme, "App")
        XCTAssertEqual(loaded.configuration, "Debug")
        XCTAssertNil(model.errorMessage)
    }
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
