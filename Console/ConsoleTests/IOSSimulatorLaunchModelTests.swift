import XCTest
@testable import Console

/// Picker/panel coverage for the iOS jobs Simulator sibling control.
@MainActor
final class IOSSimulatorLaunchModelTests: XCTestCase {

    private let selectedUDID = "AAAA-1111"
    private let bootedOtherUDID = "BBBB-2222"

    private var tmpRoot: URL!
    private var runner: FakeSimctlProcessRunner!
    private var model: IOSSimulatorLaunchModel!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 15
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let appURL = tmpRoot.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.console.synthetic.app"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Info.plist"))

        runner = FakeSimctlProcessRunner()
        runner.listJSON = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-4":[
          {"udid":"\(selectedUDID)","name":"iPhone 16","state":"Shutdown","isAvailable":true},
          {"udid":"\(bootedOtherUDID)","name":"iPhone 15","state":"Booted","isAvailable":true}
        ]}}
        """
        runner.buildSettingsJSON = """
        [{"target":"App","buildSettings":{
          "WRAPPER_EXTENSION":"app",
          "CODESIGNING_FOLDER_PATH":"\(appURL.path)",
          "PRODUCT_BUNDLE_IDENTIFIER":"com.from.settings"
        }}]
        """
        model = IOSSimulatorLaunchModel(service: SimulatorService(processRunner: runner))
        suiteName = "IOSSimulatorLaunchModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        model?.cancel()
        runner?.releaseAll()
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        try? FileManager.default.removeItem(at: tmpRoot)
        model = nil
        runner = nil
    }

    func testRefreshListsDevicesWithoutSelectingTheBootedOne() async throws {
        await model.refreshAndWait()
        XCTAssertEqual(Set(model.devices.map(\.udid)), Set([selectedUDID, bootedOtherUDID]))
        XCTAssertNil(model.affectedDevice(udid: nil))
        XCTAssertEqual(model.affectedDevice(udid: selectedUDID)?.name, "iPhone 16")
        XCTAssertTrue(model.affectedDeviceSummary(udid: nil).contains("will not use whichever device happens to be booted"))
        XCTAssertFalse(model.affectedDeviceSummary(udid: selectedUDID).contains(bootedOtherUDID))
    }

    func testInstallAndLaunchOnPickerSelection() async throws {
        var job = IOSBuildJob.queued(
            id: UUID(),
            kind: .build,
            profile: IOSProjectProfile(
                workspaceID: UUID(),
                projectPath: "/tmp/App.xcodeproj",
                scheme: "App",
                configuration: "Debug",
                simulatorUDID: selectedUDID
            ),
            testSelection: nil,
            resultBundleURL: tmpRoot.appendingPathComponent("job.xcresult"),
            createdAt: Date()
        )
        job.state = .succeeded
        await model.installAndWait(job: job, udid: selectedUDID)
        guard case .succeeded(let result) = model.phase else {
            return XCTFail("expected success, got \(model.phase)")
        }
        XCTAssertEqual(result.udid, selectedUDID)
        XCTAssertEqual(result.bundleIdentifier, "com.console.synthetic.app")
        XCTAssertEqual(runner.commandKinds, [
            .showBuildSettings, .list, .boot, .bootstatus, .install, .launch
        ])
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
    }

    func testMissingSavedUDIDIsShownAndNotReplacedByBootedDevice() async {
        await model.refreshAndWait()
        let summary = model.affectedDeviceSummary(udid: "MISSING-UDID")
        XCTAssertTrue(summary.contains("MISSING-UDID"))
        XCTAssertTrue(summary.contains("will not fall back"))
        XCTAssertFalse(summary.contains(bootedOtherUDID))
        XCTAssertFalse(model.canInstall(job: nil, udid: "MISSING-UDID"))
    }

    func testPickerSelectionWritesProfileUDID() {
        let store = IOSProjectProfileStore(defaults: defaults)
        let workspaceID = UUID()
        model.selectSimulator(selectedUDID, workspaceID: workspaceID, store: store)
        XCTAssertEqual(store.profile(for: workspaceID)?.simulatorUDID, selectedUDID)
        model.selectSimulator(nil, workspaceID: workspaceID, store: store)
        XCTAssertNil(store.profile(for: workspaceID)?.simulatorUDID)
    }
}
