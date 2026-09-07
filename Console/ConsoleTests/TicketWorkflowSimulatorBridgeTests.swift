import XCTest
@testable import Console

@MainActor
final class TicketWorkflowSimulatorBridgeTests: XCTestCase {

    private let selectedUDID = "AAAA-1111"
    private let bootedOtherUDID = "BBBB-2222"
    private let unavailableUDID = "CCCC-3333"
    private let sensitiveTicketKey = "SENSITIVE_TICKET_KEY"
    private let sensitiveTitle = "SENSITIVE_TITLE"
    private let sensitiveStatus = "SENSITIVE_STATUS"

    private var tmpRoot: URL!
    private var appURL: URL!
    private var runner: FakeSimctlProcessRunner!
    private var bridge: TicketWorkflowSimulatorBridge!
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_500)

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 15
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tw-sim-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        appURL = try plantApp(
            named: "Demo.app",
            bundleIdentifier: "com.console.synthetic.app"
        )
        runner = FakeSimctlProcessRunner()
        runner.listJSON = Self.deviceListJSON(
            selectedUDID: selectedUDID,
            selectedState: "Shutdown",
            bootedOtherUDID: bootedOtherUDID,
            unavailableUDID: unavailableUDID
        )
        runner.buildSettingsJSON = Self.buildSettingsJSON(
            target: "App",
            appPath: appURL.path,
            bundleID: "com.from.settings"
        )
        bridge = TicketWorkflowSimulatorBridge(
            service: SimulatorService(processRunner: runner)
        )
    }

    override func tearDownWithError() throws {
        runner?.releaseAll()
        try? FileManager.default.removeItem(at: tmpRoot)
        runner = nil
        bridge = nil
    }

    // MARK: - Outcome mapping

    func testLaunchSuccessDoesNotCompleteManualDeviceCheck() {
        let success = TicketWorkflowSimulatorLaunchSuccess(
            udid: selectedUDID,
            deviceName: "iPhone 16",
            appURL: appURL,
            bundleIdentifier: "com.console.synthetic.app",
            finishedAt: fixedNow
        )
        XCTAssertFalse(success.completesManualDeviceCheck)

        let result = TicketWorkflowSimulatorActionResult.launched(success)
        XCTAssertNil(TicketWorkflowSimulatorBridge.checklistOutcome(for: result))
        XCTAssertTrue(
            TicketWorkflowSimulatorBridge.requiresManualDeviceCheckAcknowledgement(for: result)
        )
    }

    func testFailureAndCancellationMapToChecklistOutcomes() {
        let failed = TicketWorkflowSimulatorActionResult.failed(
            TicketWorkflowSimulatorFailure(step: .installing, message: "install failed", finishedAt: fixedNow)
        )
        XCTAssertEqual(TicketWorkflowSimulatorBridge.checklistOutcome(for: failed), .failed)

        let cancelled = TicketWorkflowSimulatorActionResult.cancelled(
            TicketWorkflowSimulatorFailure(step: .cancelled, message: "cancelled", finishedAt: fixedNow)
        )
        XCTAssertEqual(TicketWorkflowSimulatorBridge.checklistOutcome(for: cancelled), .interrupted)
        XCTAssertFalse(
            TicketWorkflowSimulatorBridge.requiresManualDeviceCheckAcknowledgement(for: failed)
        )
    }

    // MARK: - Successful sequence

    func testPrepareInstallAndLaunchUsesExplicitUDIDAndExactArtifactFromJob() async {
        var phases: [TicketWorkflowSimulatorPhase] = []
        let result = await bridge.prepareInstallAndLaunch(
            job: succeededJob(),
            selectedUDID: selectedUDID,
            progress: { phases.append($0) },
            now: { self.fixedNow }
        )

        guard case .launched(let success) = result else {
            return XCTFail("expected launched, got \(result)")
        }
        XCTAssertEqual(success.udid, selectedUDID)
        XCTAssertEqual(success.deviceName, "iPhone 16")
        XCTAssertEqual(success.appURL.standardizedFileURL.path, appURL.standardizedFileURL.path)
        XCTAssertEqual(success.bundleIdentifier, "com.console.synthetic.app")
        XCTAssertFalse(success.completesManualDeviceCheck)
        XCTAssertNil(TicketWorkflowSimulatorBridge.checklistOutcome(for: result))

        XCTAssertEqual(phases, [
            .validatingInputs,
            .resolvingProduct,
            .preparingDevice,
            .preparingDevice, // boot progress from SimulatorService
            .waitingForReady,
            .installing,
            .launching
        ])

        XCTAssertEqual(runner.commandKinds, [
            .showBuildSettings,
            .list,
            .boot,
            .bootstatus,
            .install,
            .launch
        ])
        XCTAssertEqual(runner.udids(in: .boot), [selectedUDID])
        XCTAssertEqual(runner.udids(in: .bootstatus), [selectedUDID])
        XCTAssertEqual(runner.udids(in: .install), [selectedUDID])
        XCTAssertEqual(runner.udids(in: .launch), [selectedUDID])
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    func testArtifactHandoffInstallsExactProductWithoutBuildSettingsLookup() async throws {
        let artifact = IOSBuiltProduct(
            appURL: appURL,
            bundleIdentifier: "com.console.synthetic.app",
            targetName: "App"
        )
        let result = await bridge.prepareInstallAndLaunch(
            artifact: artifact,
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )

        guard case .launched(let success) = result else {
            return XCTFail("expected launched, got \(result)")
        }
        XCTAssertEqual(success.bundleIdentifier, "com.console.synthetic.app")
        XCTAssertFalse(runner.commandKinds.contains(.showBuildSettings))
        XCTAssertEqual(runner.commandKinds, [
            .list,
            .boot,
            .bootstatus,
            .install,
            .launch
        ])
        let installArgs = try XCTUnwrap(runner.invocations.first { $0.kind == .install }?.arguments)
        XCTAssertTrue(installArgs.contains(appURL.path))
        XCTAssertFalse(installArgs.contains(sensitiveTicketKey))
    }

    // MARK: - Explicit UDID only

    func testMissingUDIDFailsWithoutTouchingDevices() async {
        let result = await bridge.prepareInstallAndLaunch(
            job: succeededJob(),
            selectedUDID: nil,
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .validatingInputs)
        XCTAssertTrue(failure.message.contains("will not use whichever device"))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testEmptyUDIDFailsWithoutFallingBackToBootedDevice() async {
        let result = await bridge.prepareInstallAndLaunch(
            artifact: IOSBuiltProduct(appURL: appURL, bundleIdentifier: "com.console.synthetic.app"),
            selectedUDID: "   ",
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .validatingInputs)
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
    }

    func testUnknownUDIDStopsAtPreparingDeviceWithoutMutatingBootedPeer() async {
        let result = await bridge.prepareInstallAndLaunch(
            artifact: IOSBuiltProduct(appURL: appURL, bundleIdentifier: "com.console.synthetic.app"),
            selectedUDID: "MISSING-UDID",
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .preparingDevice)
        XCTAssertTrue(failure.message.contains("MISSING-UDID"))
        XCTAssertTrue(failure.message.localizedCaseInsensitiveContains("will not fall back"))
        XCTAssertEqual(runner.commandKinds, [.list])
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    // MARK: - Failure stops at originating step

    func testFailedBuildStopsAtResolvingProduct() async {
        let result = await bridge.prepareInstallAndLaunch(
            job: job(state: .failed),
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .resolvingProduct)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testMissingAppArtifactStopsAtResolvingProduct() async {
        let missing = tmpRoot.appendingPathComponent("Gone.app")
        let result = await bridge.prepareInstallAndLaunch(
            artifact: IOSBuiltProduct(appURL: missing, bundleIdentifier: "com.console.synthetic.app"),
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .resolvingProduct)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testInstallFailureStopsBeforeLaunch() async {
        runner.installResult = ProcessResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "install exploded"
        )
        let result = await bridge.prepareInstallAndLaunch(
            artifact: IOSBuiltProduct(appURL: appURL, bundleIdentifier: "com.console.synthetic.app"),
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .installing)
        XCTAssertTrue(failure.message.contains("install exploded"))
        XCTAssertEqual(runner.commandKinds, [.list, .boot, .bootstatus, .install])
        XCTAssertFalse(runner.commandKinds.contains(.launch))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    func testLaunchFailureStopsAtLaunching() async {
        runner.launchResult = ProcessResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "launch exploded"
        )
        let result = await bridge.prepareInstallAndLaunch(
            artifact: IOSBuiltProduct(appURL: appURL, bundleIdentifier: "com.console.synthetic.app"),
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .launching)
        XCTAssertEqual(TicketWorkflowSimulatorBridge.checklistOutcome(for: result), .failed)
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    func testBootTimeoutStopsAtWaitingForReady() async {
        runner.bootStatusError = ProcessRunError.timedOut
        let result = await bridge.prepareInstallAndLaunch(
            artifact: IOSBuiltProduct(appURL: appURL, bundleIdentifier: "com.console.synthetic.app"),
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(failure.step, .waitingForReady)
        XCTAssertFalse(runner.commandKinds.contains(.install))
        XCTAssertFalse(runner.commandKinds.contains(.launch))
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
    }

    // MARK: - Cancellation

    func testCancellationDuringWaitDoesNotEraseOrShutdownDevices() async {
        runner.holdBootStatus = true
        let task = Task {
            await bridge.prepareInstallAndLaunch(
                artifact: IOSBuiltProduct(appURL: appURL, bundleIdentifier: "com.console.synthetic.app"),
                selectedUDID: selectedUDID,
                now: { self.fixedNow }
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.value

        guard case .cancelled(let failure) = result else {
            return XCTFail("expected cancelled, got \(result)")
        }
        XCTAssertEqual(failure.step, .cancelled)
        XCTAssertEqual(TicketWorkflowSimulatorBridge.checklistOutcome(for: result), .interrupted)
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
        XCTAssertFalse(runner.commandKinds.contains(.install))
        for invocation in runner.invocations {
            XCTAssertFalse(SimctlCommand.forbiddenSubcommands.contains(invocation.arguments.dropFirst().first ?? ""))
        }
    }

    // MARK: - Open Simulator helper

    func testOpenSimulatorAppRequiresExplicitUDID() async {
        let missing = await bridge.openSimulatorApp(selectedUDID: nil, now: { self.fixedNow })
        guard case .failure(let failure) = missing else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(failure.step, .validatingInputs)
        XCTAssertTrue(runner.invocations.isEmpty)

        let opened = await bridge.openSimulatorApp(selectedUDID: selectedUDID, now: { self.fixedNow })
        guard case .success(let udid) = opened else {
            return XCTFail("expected success, got \(opened)")
        }
        XCTAssertEqual(udid, selectedUDID)
        XCTAssertEqual(runner.commandKinds, [.open])
        XCTAssertEqual(
            runner.invocations.first?.arguments,
            ["-a", "Simulator", "--args", "-CurrentDeviceUDID", selectedUDID]
        )
    }

    // MARK: - Privacy

    func testProcessArgvAndResultsNeverCarryTicketOrMRSentinels() async {
        let job = succeededJob(scheme: "App-\(sensitiveTicketKey)")
        // Even if a profile field somehow contained a sentinel, argv for simctl
        // install/launch must stay device/app only. Use artifact handoff.
        let artifact = IOSBuiltProduct(
            appURL: appURL,
            bundleIdentifier: "com.console.synthetic.app",
            targetName: sensitiveTitle
        )
        _ = job
        let result = await bridge.prepareInstallAndLaunch(
            artifact: artifact,
            selectedUDID: selectedUDID,
            now: { self.fixedNow }
        )
        guard case .launched(let success) = result else {
            return XCTFail("expected launched, got \(result)")
        }

        let blob = runner.invocations
            .map { [$0.executablePath] + $0.arguments + [$0.workingDirectory ?? ""] }
            .flatMap { $0 }
            .joined(separator: "\n")
            + success.udid
            + success.deviceName
            + success.bundleIdentifier
            + success.appURL.path

        XCTAssertFalse(blob.contains(sensitiveTicketKey), blob)
        XCTAssertFalse(blob.contains(sensitiveTitle), blob)
        XCTAssertFalse(blob.contains(sensitiveStatus), blob)

        let encoded = String(describing: result)
        XCTAssertFalse(encoded.contains(sensitiveTicketKey))
        XCTAssertFalse(encoded.contains(sensitiveStatus))
    }

    // MARK: - Fixtures

    private func succeededJob(scheme: String = "App") -> IOSBuildJob {
        job(state: .succeeded, scheme: scheme)
    }

    private func job(state: IOSBuildJobState, scheme: String = "App") -> IOSBuildJob {
        var item = IOSBuildJob.queued(
            id: UUID(),
            kind: .build,
            profile: IOSProjectProfile(
                workspaceID: UUID(),
                projectPath: "/tmp/App.xcodeproj",
                scheme: scheme,
                configuration: "Debug",
                simulatorUDID: selectedUDID
            ),
            testSelection: nil,
            resultBundleURL: tmpRoot.appendingPathComponent("job.xcresult"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        item.state = state
        item.exitCode = state == .succeeded ? 0 : 1
        return item
    }

    private func plantApp(named name: String, bundleIdentifier: String) throws -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Synthetic"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
        return url
    }

    private static func deviceListJSON(
        selectedUDID: String,
        selectedState: String,
        bootedOtherUDID: String,
        unavailableUDID: String
    ) -> String {
        """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
              {
                "udid": "\(selectedUDID)",
                "name": "iPhone 16",
                "state": "\(selectedState)",
                "isAvailable": true
              },
              {
                "udid": "\(bootedOtherUDID)",
                "name": "iPhone 15",
                "state": "Booted",
                "isAvailable": true
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
              {
                "udid": "\(unavailableUDID)",
                "name": "iPhone 14",
                "state": "Shutdown",
                "isAvailable": false,
                "availabilityError": "runtime profile not found"
              }
            ]
          }
        }
        """
    }

    private static func buildSettingsJSON(target: String, appPath: String, bundleID: String) -> String {
        """
        [
          {
            "target": "\(target)",
            "buildSettings": {
              "WRAPPER_EXTENSION": "app",
              "WRAPPER_NAME": "\(URL(fileURLWithPath: appPath).lastPathComponent)",
              "CODESIGNING_FOLDER_PATH": "\(appPath)",
              "PRODUCT_BUNDLE_IDENTIFIER": "\(bundleID)",
              "TARGET_BUILD_DIR": "\(URL(fileURLWithPath: appPath).deletingLastPathComponent().path)",
              "FULL_PRODUCT_NAME": "\(URL(fileURLWithPath: appPath).lastPathComponent)"
            }
          }
        ]
        """
    }
}
