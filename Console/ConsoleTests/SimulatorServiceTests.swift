import XCTest
@testable import Console

@MainActor
final class SimulatorServiceTests: XCTestCase {

    private let selectedUDID = "AAAA-1111"
    private let bootedOtherUDID = "BBBB-2222"
    private let unavailableUDID = "CCCC-3333"

    private var tmpRoot: URL!
    private var appURL: URL!
    private var runner: FakeSimctlProcessRunner!
    private var service: SimulatorService!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 15
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        appURL = try plantApp(
            named: "WrongName.app",
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
        service = SimulatorService(processRunner: runner)
    }

    override func tearDownWithError() throws {
        runner?.releaseAll()
        try? FileManager.default.removeItem(at: tmpRoot)
        runner = nil
        service = nil
    }

    // MARK: - Parsers

    func testDeviceListParserKeepsTypedIOSDevicesAndAvailability() throws {
        let devices = try SimulatorDeviceListParser.devices(from: runner.listJSON)
        XCTAssertEqual(
            Set(devices.map(\.udid)),
            Set([selectedUDID, bootedOtherUDID, unavailableUDID])
        )
        let selected = try XCTUnwrap(devices.first { $0.udid == selectedUDID })
        XCTAssertEqual(selected.name, "iPhone 16")
        XCTAssertEqual(selected.state, .shutdown)
        XCTAssertTrue(selected.isAvailable)
        XCTAssertTrue(selected.displayName.contains("iOS 18.4"))

        let booted = try XCTUnwrap(devices.first { $0.udid == bootedOtherUDID })
        XCTAssertEqual(booted.state, .booted)

        let unavailable = try XCTUnwrap(devices.first { $0.udid == unavailableUDID })
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertEqual(unavailable.availabilityError, "runtime profile not found")
    }

    func testDeviceListParserDropsWatchAndTVRuntimes() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[
            {"udid":"WATCH","name":"Apple Watch","state":"Shutdown","isAvailable":true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-4":[
            {"udid":"PHONE","name":"iPhone 16","state":"Shutdown","isAvailable":true}
          ]
        }}
        """
        let devices = try SimulatorDeviceListParser.devices(from: json)
        XCTAssertEqual(devices.map(\.udid), ["PHONE"])
    }

    func testBuildSettingsParserPrefersSchemeMatchedApp() throws {
        let output = """
        [
          {"target":"AppTests","buildSettings":{
            "WRAPPER_EXTENSION":"xctest",
            "CODESIGNING_FOLDER_PATH":"/tmp/AppTests.xctest",
            "PRODUCT_BUNDLE_IDENTIFIER":"com.example.tests"
          }},
          {"target":"App","buildSettings":{
            "WRAPPER_EXTENSION":"app",
            "CODESIGNING_FOLDER_PATH":"\(appURL.path)",
            "PRODUCT_BUNDLE_IDENTIFIER":"com.from.settings"
          }}
        ]
        """
        let product = try IOSBuildSettingsParser.product(from: output, scheme: "App")
        XCTAssertEqual(product.appPath, appURL.path)
        XCTAssertEqual(product.bundleID, "com.from.settings")
        XCTAssertEqual(product.targetName, "App")
    }

    func testBuildSettingsParserRefusesToGuessAmongMultipleApps() {
        let output = """
        [
          {"target":"One","buildSettings":{
            "WRAPPER_EXTENSION":"app",
            "CODESIGNING_FOLDER_PATH":"/tmp/One.app",
            "PRODUCT_BUNDLE_IDENTIFIER":"com.one"
          }},
          {"target":"Two","buildSettings":{
            "WRAPPER_EXTENSION":"app",
            "CODESIGNING_FOLDER_PATH":"/tmp/Two.app",
            "PRODUCT_BUNDLE_IDENTIFIER":"com.two"
          }}
        ]
        """
        XCTAssertThrowsError(try IOSBuildSettingsParser.product(from: output, scheme: "App")) { error in
            let message = (error as? SimulatorServiceError)?.localizedDescription ?? ""
            XCTAssertTrue(message.contains("will not guess"), message)
        }
    }

    func testBuildSettingsTextParserReadsCodesigningFolder() throws {
        let output = """
        Build settings for action build and target "App":
            WRAPPER_EXTENSION = app
            CODESIGNING_FOLDER_PATH = \(appURL.path)
            PRODUCT_BUNDLE_IDENTIFIER = com.from.text
        """
        let product = try IOSBuildSettingsParser.product(from: output, scheme: "App")
        XCTAssertEqual(product.appPath, appURL.path)
        XCTAssertEqual(product.bundleID, "com.from.text")
    }

    func testSimctlArgvIsStructuredAndNeverDestructive() {
        let boot = SimctlCommand.boot(udid: selectedUDID)
        XCTAssertEqual(boot.executablePath, "/usr/bin/xcrun")
        XCTAssertEqual(boot.arguments, ["simctl", "boot", selectedUDID])
        XCTAssertFalse(boot.arguments.contains("-c"))
        XCTAssertFalse(boot.executablePath.contains("zsh"))

        for spec in [
            SimctlCommand.listDevices(),
            SimctlCommand.boot(udid: selectedUDID),
            SimctlCommand.bootStatus(udid: selectedUDID),
            SimctlCommand.install(udid: selectedUDID, appPath: appURL.path),
            SimctlCommand.launch(udid: selectedUDID, bundleIdentifier: "com.console.synthetic.app")
        ] {
            XCTAssertEqual(spec.arguments.first, "simctl")
            XCTAssertFalse(SimctlCommand.forbiddenSubcommands.contains(spec.arguments[1]))
        }

        let open = SimctlCommand.openSimulatorApp(udid: selectedUDID)
        XCTAssertEqual(open.executablePath, "/usr/bin/open")
        XCTAssertEqual(open.arguments, ["-a", "Simulator", "--args", "-CurrentDeviceUDID", selectedUDID])
    }

    // MARK: - Successful sequence

    func testSuccessfulInstallLaunchesExplicitUDIDUsingPlistBundleID() async throws {
        var phases: [SimulatorInstallPhase] = []
        let result = try await service.installAndLaunch(
            job: succeededJob(),
            udid: selectedUDID
        ) { phases.append($0) }

        XCTAssertEqual(result.udid, selectedUDID)
        XCTAssertEqual(result.deviceName, "iPhone 16")
        XCTAssertEqual(result.appURL.standardizedFileURL.path, appURL.standardizedFileURL.path)
        XCTAssertEqual(result.bundleIdentifier, "com.console.synthetic.app")
        XCTAssertNotEqual(result.bundleIdentifier, "WrongName")
        XCTAssertNotEqual(result.bundleIdentifier, "com.from.settings")
        XCTAssertEqual(phases, [
            .resolvingProduct,
            .listingDevices,
            .booting,
            .waitingForReady,
            .installing,
            .launching
        ])

        let kinds = runner.commandKinds
        XCTAssertEqual(kinds, [
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
        XCTAssertFalse(runner.udids(in: .boot).contains(bootedOtherUDID))
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)

        let installArgs = try XCTUnwrap(runner.invocations.first { $0.kind == .install }).arguments
        XCTAssertEqual(installArgs.last, appURL.path)
        let launchArgs = try XCTUnwrap(runner.invocations.first { $0.kind == .launch }).arguments
        XCTAssertEqual(launchArgs.last, "com.console.synthetic.app")
        XCTAssertFalse(launchArgs.contains("WrongName"))

        let settingsArgs = try XCTUnwrap(runner.invocations.first { $0.kind == .showBuildSettings }).arguments
        XCTAssertEqual(value(after: "-destination", in: settingsArgs), "platform=iOS Simulator,id=\(selectedUDID)")
        XCTAssertEqual(value(after: "-scheme", in: settingsArgs), "App")
        XCTAssertFalse(settingsArgs.contains("zsh"))
        XCTAssertFalse(settingsArgs.contains("-c"))
    }

    func testAlreadyBootedDeviceSkipsBootAndStillWaits() async throws {
        runner.listJSON = Self.deviceListJSON(
            selectedUDID: selectedUDID,
            selectedState: "Booted",
            bootedOtherUDID: bootedOtherUDID,
            unavailableUDID: unavailableUDID
        )
        _ = try await service.installAndLaunch(job: succeededJob(), udid: selectedUDID)
        XCTAssertEqual(runner.commandKinds, [
            .showBuildSettings,
            .list,
            .bootstatus,
            .install,
            .launch
        ])
        XCTAssertFalse(runner.commandKinds.contains(.boot))
        XCTAssertEqual(runner.udids(in: .bootstatus), [selectedUDID])
    }

    // MARK: - Failures stop at the right step

    func testFailedBuildStopsBeforeAnyTool() async throws {
        do {
            _ = try await service.installAndLaunch(job: job(state: .failed), udid: selectedUDID)
            XCTFail("expected failed build")
        } catch let error as SimulatorServiceError {
            XCTAssertEqual(error, .failedBuild(.failed))
            XCTAssertTrue(error.localizedDescription.contains("successful build"))
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testCancelledAndTimedOutJobsAreFailedBuilds() async throws {
        for state in [IOSBuildJobState.cancelled, .timedOut, .running, .queued] {
            runner.invocationsStorageRemoveAll()
            do {
                _ = try await service.installAndLaunch(job: job(state: state), udid: selectedUDID)
                XCTFail("expected failure for \(state)")
            } catch let error as SimulatorServiceError {
                XCTAssertEqual(error, .failedBuild(state))
            }
            XCTAssertTrue(runner.invocations.isEmpty, "\(state) must not start simctl")
        }
    }

    func testMissingAppStopsBeforeSimctl() async throws {
        let missing = tmpRoot.appendingPathComponent("Missing.app").path
        runner.buildSettingsJSON = Self.buildSettingsJSON(
            target: "App",
            appPath: missing,
            bundleID: "com.missing"
        )
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: selectedUDID)
            XCTFail("expected missing app")
        } catch let error as SimulatorServiceError {
            XCTAssertEqual(error, .missingApp(missing))
            XCTAssertTrue(error.localizedDescription.contains(missing))
        }
        XCTAssertEqual(runner.commandKinds, [.showBuildSettings])
        XCTAssertFalse(runner.commandKinds.contains(.list))
        XCTAssertFalse(runner.commandKinds.contains(.install))
    }

    func testUnavailableRuntimeStopsBeforeBoot() async throws {
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: unavailableUDID)
            XCTFail("expected unavailable runtime")
        } catch let error as SimulatorServiceError {
            guard case .unavailableRuntime(let udid, _, _) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(udid, unavailableUDID)
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
        XCTAssertEqual(runner.commandKinds, [.showBuildSettings, .list])
        XCTAssertFalse(runner.commandKinds.contains(.boot))
        XCTAssertFalse(runner.commandKinds.contains(.install))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    func testMissingUDIDDoesNotFallBackToBootedDevice() async throws {
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: "DEAD-BEEF")
            XCTFail("expected device not found")
        } catch let error as SimulatorServiceError {
            XCTAssertEqual(error, .deviceNotFound("DEAD-BEEF"))
            XCTAssertTrue(error.localizedDescription.contains("will not fall back"))
        }
        XCTAssertEqual(runner.commandKinds, [.showBuildSettings, .list])
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
        XCTAssertFalse(runner.commandKinds.contains(.boot))
    }

    func testEmptyUDIDDoesNotUseBootedDevice() async throws {
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: "  ")
            XCTFail("expected missing simulator")
        } catch let error as SimulatorServiceError {
            XCTAssertEqual(error, .missingSimulator)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testBootTimeoutStopsBeforeInstall() async throws {
        runner.bootStatusError = ProcessRunError.timedOut
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: selectedUDID)
            XCTFail("expected boot timeout")
        } catch let error as SimulatorServiceError {
            XCTAssertEqual(error, .bootTimedOut(selectedUDID))
            XCTAssertTrue(error.localizedDescription.contains("Timed out"))
        }
        XCTAssertEqual(runner.commandKinds, [
            .showBuildSettings,
            .list,
            .boot,
            .bootstatus
        ])
        XCTAssertFalse(runner.commandKinds.contains(.install))
        XCTAssertFalse(runner.commandKinds.contains(.launch))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    func testInstallFailureStopsBeforeLaunch() async throws {
        runner.installResult = ProcessResult(
            exitCode: 2,
            standardOutput: "",
            standardError: "An error was encountered: Invalid bundle"
        )
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: selectedUDID)
            XCTFail("expected install failure")
        } catch let error as SimulatorServiceError {
            guard case .installFailed(let detail) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(detail.contains("Invalid bundle"), detail)
            XCTAssertTrue(error.localizedDescription.contains("Installing"))
        }
        XCTAssertTrue(runner.commandKinds.contains(.install))
        XCTAssertFalse(runner.commandKinds.contains(.launch))
    }

    func testLaunchFailureReportsAfterInstall() async throws {
        runner.launchResult = ProcessResult(
            exitCode: 4,
            standardOutput: "",
            standardError: "The bundle identifier is invalid"
        )
        do {
            _ = try await service.installAndLaunch(job: succeededJob(), udid: selectedUDID)
            XCTFail("expected launch failure")
        } catch let error as SimulatorServiceError {
            guard case .launchFailed(let detail) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(detail.contains("bundle identifier is invalid"), detail)
        }
        XCTAssertEqual(runner.commandKinds.last, .launch)
        XCTAssertTrue(runner.commandKinds.contains(.install))
    }

    func testCancelDuringBootStatusDoesNotTouchUnrelatedSimulator() async throws {
        runner.holdBootStatus = true
        let task = Task {
            try await self.service.installAndLaunch(job: self.succeededJob(), udid: self.selectedUDID)
        }
        try await waitUntil {
            self.runner.commandKinds.contains(.bootstatus)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as SimulatorServiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // also acceptable
        }
        XCTAssertFalse(runner.commandKinds.contains(.install))
        XCTAssertFalse(runner.commandKinds.contains(.launch))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
        XCTAssertEqual(Set(runner.mutatedUDIDs), Set([selectedUDID]))
    }

    func testOpenSimulatorUsesExplicitUDID() async throws {
        try await service.openSimulator(udid: selectedUDID)
        XCTAssertEqual(runner.commandKinds, [.open])
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executablePath, "/usr/bin/open")
        XCTAssertEqual(invocation.arguments, [
            "-a", "Simulator", "--args", "-CurrentDeviceUDID", selectedUDID
        ])
        XCTAssertFalse(invocation.arguments.contains(bootedOtherUDID))
    }

    func testResolveProductUsesInstallDestinationUDIDOverJobSnapshot() async throws {
        let appURL = try plantApp(named: "App.app", bundleIdentifier: "com.console.synthetic.app")
        runner.buildSettingsJSON = Self.buildSettingsJSON(
            target: "App",
            appPath: appURL.path,
            bundleID: "com.console.synthetic.app"
        )
        let job = succeededJob()

        _ = try await service.resolveProduct(from: job, destinationUDID: bootedOtherUDID)

        let invocation = try XCTUnwrap(runner.invocations.first { $0.kind == .showBuildSettings })
        XCTAssertTrue(invocation.arguments.contains("platform=iOS Simulator,id=\(bootedOtherUDID)"))
        XCTAssertFalse(invocation.arguments.contains("platform=iOS Simulator,id=\(selectedUDID)"))

        _ = try await service.resolveProduct(from: job)
        let fallback = runner.invocations.filter { $0.kind == .showBuildSettings }.last
        XCTAssertTrue(try XCTUnwrap(fallback).arguments.contains("platform=iOS Simulator,id=\(selectedUDID)"))
    }

    func testProductFallsBackToBuildSettingsBundleIDWhenPlistMissing() async throws {
        let bare = tmpRoot.appendingPathComponent("Bare.app")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        runner.buildSettingsJSON = Self.buildSettingsJSON(
            target: "App",
            appPath: bare.path,
            bundleID: "com.from.settings"
        )
        let product = try await service.resolveProduct(from: succeededJob())
        XCTAssertEqual(product.bundleIdentifier, "com.from.settings")
        XCTAssertNotEqual(product.bundleIdentifier, "Bare")
    }

    // MARK: - Picker / panel model

    func testAffectedDeviceSummaryNamesTheExplicitUDID() async throws {
        let model = IOSSimulatorLaunchModel(service: service)
        await model.refreshAndWait()
        XCTAssertTrue(
            model.affectedDeviceSummary(udid: selectedUDID).contains("iPhone 16"),
            model.affectedDeviceSummary(udid: selectedUDID)
        )
        XCTAssertTrue(model.affectedDeviceSummary(udid: selectedUDID).contains(selectedUDID))
        XCTAssertFalse(model.affectedDeviceSummary(udid: selectedUDID).contains(bootedOtherUDID))

        let missing = model.affectedDeviceSummary(udid: "DEAD-BEEF")
        XCTAssertTrue(missing.contains("DEAD-BEEF"))
        XCTAssertTrue(missing.contains("will not fall back"))
        XCTAssertFalse(missing.contains(bootedOtherUDID))

        let empty = model.affectedDeviceSummary(udid: nil)
        XCTAssertTrue(empty.contains("will not use whichever device happens to be booted"))
    }

    func testCanInstallRequiresSuccessfulJobAndExplicitUDID() {
        let model = IOSSimulatorLaunchModel(service: service)
        XCTAssertFalse(model.canInstall(job: succeededJob(), udid: nil))
        XCTAssertFalse(model.canInstall(job: job(state: .failed), udid: selectedUDID))
        XCTAssertFalse(model.canInstall(job: job(state: .running), udid: selectedUDID))
        XCTAssertTrue(model.canInstall(job: succeededJob(), udid: selectedUDID))
    }

    func testModelFailedBuildDoesNotInvokeSimctl() async {
        let model = IOSSimulatorLaunchModel(service: service)
        await model.installAndWait(job: job(state: .failed), udid: selectedUDID)
        XCTAssertEqual(
            model.phase,
            .failed(SimulatorServiceError.failedBuild(.failed).localizedDescription)
        )
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
    }

    func testModelCancelWaitingDoesNotAffectUnrelatedSimulator() async throws {
        runner.holdBootStatus = true
        let model = IOSSimulatorLaunchModel(service: service)
        model.installAndLaunch(job: succeededJob(), udid: selectedUDID)
        try await waitUntil { self.runner.commandKinds.contains(.bootstatus) }
        XCTAssertTrue(model.canCancelWait)
        model.cancelWaiting()
        try await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("cancelled"), message)
        } else {
            XCTFail("expected cancelled phase, got \(model.phase)")
        }
        XCTAssertFalse(runner.commandKinds.contains(.install))
        XCTAssertTrue(runner.destructiveInvocations.isEmpty)
        XCTAssertFalse(runner.mutatedUDIDs.contains(bootedOtherUDID))
    }

    func testSelectSimulatorPersistsExplicitUDIDWithoutGuessingBootedDevice() {
        let suite = "sim-picker-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = IOSProjectProfileStore(defaults: defaults)
        let workspaceID = UUID()
        let model = IOSSimulatorLaunchModel(service: service)
        model.selectSimulator(selectedUDID, workspaceID: workspaceID, store: store)
        XCTAssertEqual(store.profile(for: workspaceID)?.simulatorUDID, selectedUDID)
        XCTAssertNotEqual(store.profile(for: workspaceID)?.simulatorUDID, bootedOtherUDID)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Fixtures

    private func succeededJob() -> IOSBuildJob {
        job(state: .succeeded)
    }

    private func job(state: IOSBuildJobState) -> IOSBuildJob {
        var item = IOSBuildJob.queued(
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

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func waitUntil(seconds: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        struct TestTimeout: LocalizedError {
            var errorDescription: String? { "waitUntil timed out" }
        }
        throw TestTimeout()
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
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
              {
                "udid": "WATCH-1",
                "name": "Apple Watch",
                "state": "Shutdown",
                "isAvailable": true
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

final class FakeSimctlProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executablePath: String
        var arguments: [String]
        var workingDirectory: String?
        var deadline: Date?
        var kind: Kind

        enum Kind: Equatable, Sendable {
            case list
            case boot
            case bootstatus
            case install
            case launch
            case showBuildSettings
            case open
            case destructive
            case other
        }
    }

    private let lock = NSLock()
    private var invocationsStorage: [Invocation] = []
    private var releasedCount = 0
    private var stopHolds = false

    var listJSON = "{}"
    var buildSettingsJSON = "[]"
    var failJSONBuildSettings = false
    var holdBootStatus = false
    var bootResult = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    var bootStatusResult = ProcessResult(exitCode: 0, standardOutput: "Monitoring boot status", standardError: "")
    var bootStatusError: Error?
    var installResult = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    var launchResult = ProcessResult(exitCode: 0, standardOutput: "com.console.synthetic.app: 12345", standardError: "")
    var openResult = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocationsStorage
    }

    var commandKinds: [Invocation.Kind] {
        invocations.map(\.kind)
    }

    var destructiveInvocations: [Invocation] {
        invocations.filter { $0.kind == .destructive }
    }

    var mutatedUDIDs: [String] {
        invocations.compactMap { invocation in
            switch invocation.kind {
            case .boot, .bootstatus, .install, .launch:
                guard invocation.arguments.count >= 3, invocation.arguments[0] == "simctl" else {
                    return nil
                }
                return invocation.arguments[2]
            default:
                return nil
            }
        }
    }

    func invocationsStorageRemoveAll() {
        lock.lock()
        invocationsStorage.removeAll()
        lock.unlock()
    }

    func udids(in kind: Invocation.Kind) -> [String] {
        invocations.filter { $0.kind == kind }.compactMap { invocation in
            guard invocation.arguments.count >= 3, invocation.arguments[0] == "simctl" else {
                return nil
            }
            return invocation.arguments[2]
        }
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
        let kind = Invocation.Kind.classify(executablePath: executablePath, arguments: arguments)
        let invocation = Invocation(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            deadline: deadline,
            kind: kind
        )
        lock.lock()
        invocationsStorage.append(invocation)
        let shouldHold = holdBootStatus && kind == .bootstatus
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

        if Task.isCancelled { throw ProcessRunError.cancelled }

        switch kind {
        case .list:
            return ProcessResult(exitCode: 0, standardOutput: listJSON, standardError: "")
        case .showBuildSettings:
            if failJSONBuildSettings, arguments.contains("-json") {
                return ProcessResult(exitCode: 64, standardOutput: "", standardError: "invalid option '-json'")
            }
            return ProcessResult(exitCode: 0, standardOutput: buildSettingsJSON, standardError: "")
        case .boot:
            return bootResult
        case .bootstatus:
            if let bootStatusError { throw bootStatusError }
            return bootStatusResult
        case .install:
            return installResult
        case .launch:
            return launchResult
        case .open:
            return openResult
        case .destructive:
            return ProcessResult(exitCode: 1, standardOutput: "", standardError: "destructive simctl is forbidden")
        case .other:
            return ProcessResult(exitCode: 1, standardOutput: "", standardError: "unexpected arguments")
        }
    }
}

extension FakeSimctlProcessRunner.Invocation.Kind {
    static func classify(executablePath: String, arguments: [String]) -> Self {
        if arguments.contains("erase") || arguments.contains("shutdown")
            || arguments.contains("delete") || arguments.contains("clone") {
            return .destructive
        }
        if arguments.contains("-showBuildSettings") { return .showBuildSettings }
        if arguments.contains("bootstatus") { return .bootstatus }
        if arguments.contains("boot") { return .boot }
        if arguments.contains("install") { return .install }
        if arguments.contains("launch") { return .launch }
        if arguments.contains("list") { return .list }
        if executablePath.hasSuffix("/open") || executablePath == "/usr/bin/open" { return .open }
        return .other
    }
}
