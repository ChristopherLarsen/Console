import XCTest
@testable import Console

final class IOSProjectDiscoveryTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - JSON parser fixtures

    func testListJSONParsesProjectSchemesAndConfigurations() throws {
        let listing = try IOSXcodebuildOutputParser.listing(fromListJSON: Self.projectListJSON)
        XCTAssertEqual(listing.name, "App")
        XCTAssertEqual(listing.schemes, ["App", "AppTests"])
        XCTAssertEqual(listing.configurations, ["Debug", "Release"])
        XCTAssertEqual(listing.targets, ["App", "AppTests"])
        XCTAssertNil(listing.testPlans)
    }

    func testListJSONParsesWorkspaceAndIgnoresPreamble() throws {
        let output = """
        --- xcodebuild: WARNING: Using the first of multiple matching destinations
        \(Self.workspaceListJSON)
        """
        let listing = try IOSXcodebuildOutputParser.listing(fromListJSON: output)
        XCTAssertEqual(listing.name, "App")
        XCTAssertEqual(listing.schemes, ["App", "AppTests"])
        XCTAssertTrue(listing.configurations.isEmpty)
    }

    func testListJSONRejectsEmptyPayload() {
        XCTAssertThrowsError(try IOSXcodebuildOutputParser.listing(fromListJSON: "not json")) { error in
            guard let discoveryError = error as? IOSProjectDiscoveryError,
                  case .invalidJSON = discoveryError else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }
    }

    func testTestPlanJSONObjectAndArrayFixtures() {
        XCTAssertEqual(
            IOSXcodebuildOutputParser.testPlans(from: #"{"testPlans":["Unit","UI"]}"#),
            ["Unit", "UI"]
        )
        XCTAssertEqual(
            IOSXcodebuildOutputParser.testPlans(from: #"{"testPlans":[{"name":"Unit"},{"name":"UI"}]}"#),
            ["Unit", "UI"]
        )
        XCTAssertEqual(
            IOSXcodebuildOutputParser.testPlans(from: #"["Smoke"]"#),
            ["Smoke"]
        )
    }

    func testTestPlanTextFixture() {
        let text = """
        Test plans associated with the scheme "App":
                Unit
                UI
        """
        XCTAssertEqual(IOSXcodebuildOutputParser.testPlans(from: text), ["Unit", "UI"])
    }

    func testDestinationJSONKeepsIOSSimulatorAndDropsPlaceholders() {
        let parsed = IOSXcodebuildOutputParser.destinations(from: Self.destinationJSON)
        XCTAssertEqual(parsed.map(\.udid), ["11111111-1111-1111-1111-111111111111"])
        XCTAssertEqual(parsed.first?.name, "iPhone 16")
        XCTAssertEqual(parsed.first?.osVersion, "18.4")
    }

    func testDestinationTextParsesSpacedNameAndIgnoresMac() {
        let text = """
            Available destinations for the "App" scheme:
                { platform:macOS, arch:arm64, id:MAC-ID, name:My Mac }
                { platform:iOS Simulator, arch:arm64, id:AAAA-BBBB, OS:18.4, name:iPad Pro (12.9-inch, 6th generation) }
                { platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
        """
        let parsed = IOSXcodebuildOutputParser.destinations(from: text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.udid, "AAAA-BBBB")
        XCTAssertEqual(parsed.first?.name, "iPad Pro (12.9-inch, 6th generation)")
    }

    // MARK: - Manual selection

    func testManualSelectionAcceptsProjectBundleDirectly() throws {
        let project = try plantProject(named: "Solo.xcodeproj")
        let outcome = IOSProjectManualSelection.resolve(url: URL(fileURLWithPath: project.path))
        XCTAssertEqual(outcome, .selected(project))
    }

    func testManualSelectionAcceptsFolderWithExactlyOneProject() throws {
        let project = try plantProject(named: "Subfolder/App.xcodeproj")
        let folder = tmpRoot.appendingPathComponent("Subfolder")
        let outcome = IOSProjectManualSelection.resolve(url: folder)
        XCTAssertEqual(outcome, .selected(project))
    }

    func testManualSelectionRejectsFolderWithSeveralProjects() throws {
        _ = try plantProject(named: "Subfolder/Foo.xcodeproj")
        _ = try plantProject(named: "Subfolder/Bar.xcodeproj")
        let outcome = IOSProjectManualSelection.resolve(url: tmpRoot.appendingPathComponent("Subfolder"))
        guard case .invalid = outcome else {
            return XCTFail("Expected invalid, got \(outcome)")
        }
    }

    func testManualSelectionRejectsFolderWithoutProjects() throws {
        let outcome = IOSProjectManualSelection.resolve(url: tmpRoot)
        guard case .invalid = outcome else {
            return XCTFail("Expected invalid, got \(outcome)")
        }
    }

    // MARK: - Repair policy

    func testInvalidSavedSchemeIsKeptAndFlagged() {
        let workspaceID = UUID()
        let saved = IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: "/tmp/App.xcodeproj",
            scheme: "Gone",
            configuration: "Debug"
        )
        let listing = IOSProjectListing(
            name: "App",
            schemes: ["App"],
            configurations: ["Debug"],
            targets: ["App"],
            testPlans: ["Unit"]
        )
        let repair = IOSProfileRepair.resolve(
            saved: saved,
            listing: .succeeded(listing),
            destinations: .skipped,
            fileExists: { _ in true }
        )
        XCTAssertEqual(repair.profile.scheme, "Gone")
        XCTAssertEqual(repair.profile.configuration, "Debug")
        XCTAssertEqual(repair.issues, [.savedSchemeMissing("Gone")])
        XCTAssertFalse(repair.didChangeProfile)
    }

    func testMissingSimulatorIsKeptAndFlagged() {
        let saved = IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: "/tmp/App.xcodeproj",
            scheme: "App",
            simulatorUDID: "DEAD-BEEF"
        )
        let present = IOSSimulatorDestination(
            udid: "LIVE-UDID",
            name: "iPhone 16",
            osVersion: "18.4",
            platform: "iOS Simulator"
        )
        let repair = IOSProfileRepair.resolve(
            saved: saved,
            listing: .skipped,
            destinations: .succeeded([present]),
            fileExists: { _ in true }
        )
        XCTAssertEqual(repair.profile.simulatorUDID, "DEAD-BEEF")
        XCTAssertEqual(repair.issues, [.savedSimulatorMissing("DEAD-BEEF")])
        XCTAssertFalse(repair.didChangeProfile)
    }

    func testListingFailureDoesNotClearAValidProfile() {
        let saved = IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: "/tmp/App.xcodeproj",
            scheme: "App",
            configuration: "Debug",
            testPlan: "Unit",
            simulatorUDID: "LIVE-UDID"
        )
        let repair = IOSProfileRepair.resolve(
            saved: saved,
            listing: .failed,
            destinations: .failed,
            fileExists: { _ in true }
        )
        XCTAssertEqual(repair.profile, saved)
        XCTAssertTrue(repair.issues.isEmpty)
        XCTAssertFalse(repair.didChangeProfile)
    }

    func testUniqueSchemeFillsOnlyAnEmptyField() {
        let saved = IOSProjectProfile(workspaceID: UUID(), projectPath: "/tmp/App.xcodeproj")
        let listing = IOSProjectListing(
            name: "App",
            schemes: ["App"],
            configurations: ["Debug"],
            targets: ["App"],
            testPlans: ["Unit", "UI"]
        )
        let repair = IOSProfileRepair.resolve(
            saved: saved,
            listing: .succeeded(listing),
            destinations: .skipped,
            fileExists: { _ in true }
        )
        XCTAssertEqual(repair.profile.scheme, "App")
        XCTAssertEqual(repair.profile.configuration, "Debug")
        XCTAssertNil(repair.profile.testPlan, "a test plan is never chosen automatically")
        XCTAssertTrue(repair.didChangeProfile)
    }

    // MARK: - Argv

    func testListUsesStructuredArgvForASpacedProjectPath() async throws {
        let runner = FakeXcodebuildRunner()
        runner.listJSON = Self.projectListJSON
        let discovery = IOSProjectDiscovery(processRunner: runner)
        let path = tmpRoot.appendingPathComponent("My App").appendingPathComponent("App.xcodeproj").path
        let candidate = try XCTUnwrap(IOSProjectCandidate(path: path))

        _ = try await discovery.list(candidate)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executablePath, "/usr/bin/xcodebuild")
        XCTAssertEqual(invocation.arguments, ["-list", "-json", "-project", path])
        XCTAssertNil(invocation.workingDirectory)
        XCTAssertNotNil(invocation.deadline)
        XCTAssertFalse(invocation.arguments.contains { $0.contains(" ") && $0.contains("-project") })
    }

    func testShowTestPlansAndDestinationsUseSchemeAndWorkspaceArgv() async throws {
        let runner = FakeXcodebuildRunner()
        runner.testPlanJSON = #"{"testPlans":["Unit"]}"#
        runner.destinationJSON = Self.destinationJSON
        let discovery = IOSProjectDiscovery(processRunner: runner)
        let path = tmpRoot.appendingPathComponent("Wide Workspace").appendingPathComponent("App.xcworkspace").path
        let candidate = try XCTUnwrap(IOSProjectCandidate(path: path))

        let plans = await discovery.listTestPlans(candidate: candidate, scheme: "My Scheme")
        let destinations = await discovery.listDestinations(candidate: candidate, scheme: "My Scheme")

        XCTAssertEqual(plans, .succeeded(["Unit"]))
        XCTAssertEqual(destinations.udids, ["11111111-1111-1111-1111-111111111111"])

        let planArgs = try XCTUnwrap(runner.invocations.first(where: { $0.arguments.contains("-showTestPlans") })?.arguments)
        XCTAssertEqual(planArgs.first, "-showTestPlans")
        XCTAssertTrue(planArgs.contains("-json"))
        XCTAssertEqual(planArgs[planArgs.firstIndex(of: "-workspace")! + 1], path)
        XCTAssertEqual(planArgs[planArgs.firstIndex(of: "-scheme")! + 1], "My Scheme")

        let destinationArgs = try XCTUnwrap(runner.invocations.first(where: { $0.arguments.contains("-showdestinations") })?.arguments)
        XCTAssertEqual(destinationArgs.first, "-showdestinations")
        XCTAssertTrue(destinationArgs.contains("-json"))
        XCTAssertEqual(destinationArgs[destinationArgs.firstIndex(of: "-destination-timeout")! + 1], "8")
        XCTAssertEqual(destinationArgs[destinationArgs.firstIndex(of: "-workspace")! + 1], path)
        XCTAssertEqual(destinationArgs[destinationArgs.firstIndex(of: "-scheme")! + 1], "My Scheme")
        for invocation in runner.invocations {
            XCTAssertFalse(invocation.arguments.contains { $0.contains("&&") })
            XCTAssertNotNil(invocation.deadline)
        }
    }

    func testRefreshDoesNotLaunchABuildAction() async throws {
        let project = try plantProject(named: "App.xcodeproj")
        let runner = FakeXcodebuildRunner()
        runner.listJSON = Self.projectListJSON
        runner.testPlanJSON = #"{"testPlans":["Unit"]}"#
        runner.destinationJSON = Self.destinationJSON
        let discovery = IOSProjectDiscovery(processRunner: runner)
        let saved = IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: project.path,
            scheme: "App"
        )

        let result = await discovery.refresh(saved: saved)

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.listing?.schemes, ["App", "AppTests"])
        let actions = runner.invocations.flatMap(\.arguments)
        XCTAssertFalse(actions.contains("build"))
        XCTAssertFalse(actions.contains("test"))
        XCTAssertFalse(actions.contains("build-for-testing"))
    }

    func testRefreshPreservesProfileWhenListFails() async throws {
        let project = try plantProject(named: "App.xcodeproj")
        let runner = FakeXcodebuildRunner()
        runner.listError = ProcessRunError.timedOut
        let discovery = IOSProjectDiscovery(processRunner: runner)
        let saved = IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: project.path,
            scheme: "App",
            configuration: "Debug",
            testPlan: "Unit",
            simulatorUDID: "LIVE-UDID"
        )

        let result = await discovery.refresh(saved: saved)

        XCTAssertEqual(result.repair.profile, saved)
        XCTAssertFalse(result.repair.didChangeProfile)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertNil(result.listing)
    }

    func testRefreshDistinguishesDestinationLookupFailureFromEmptySuccess() async throws {
        let project = try plantProject(named: "App.xcodeproj")
        let saved = IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: project.path,
            scheme: "App"
        )

        let failingRunner = FakeXcodebuildRunner()
        failingRunner.listJSON = Self.projectListJSON
        failingRunner.destinationError = ProcessRunError.timedOut
        let failedResult = await IOSProjectDiscovery(processRunner: failingRunner)
            .refresh(saved: saved)
        if case .failed = failedResult.destinationLookup {} else {
            XCTFail("expected failed destination lookup, got \(failedResult.destinationLookup)")
        }
        XCTAssertTrue(failedResult.destinations.isEmpty)
        XCTAssertFalse(
            failedResult.repair.issues.contains { if case .savedSimulatorMissing = $0 { return true }; return false }
        )

        let emptyRunner = FakeXcodebuildRunner()
        emptyRunner.listJSON = Self.projectListJSON
        emptyRunner.destinationJSON = #"{"destinations":[]}"#
        let emptyResult = await IOSProjectDiscovery(processRunner: emptyRunner)
            .refresh(saved: saved)
        if case .succeeded(let devices) = emptyResult.destinationLookup {
            XCTAssertTrue(devices.isEmpty)
        } else {
            XCTFail("expected succeeded empty destination lookup, got \(emptyResult.destinationLookup)")
        }
    }

    // MARK: - Fixtures

    private func plantProject(named relative: String) throws -> IOSProjectCandidate {
        let url = tmpRoot.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try XCTUnwrap(IOSProjectCandidate(path: url.path))
    }

    private static let projectListJSON = """
    {
      "project" : {
        "configurations" : [ "Debug", "Release" ],
        "name" : "App",
        "schemes" : [ "App", "AppTests" ],
        "targets" : [ "App", "AppTests" ]
      }
    }
    """

    private static let workspaceListJSON = """
    {
      "workspace" : {
        "name" : "App",
        "schemes" : [ "App", "AppTests" ]
      }
    }
    """

    private static let destinationJSON = """
    {
      "destinations" : [
        {
          "platform" : "macOS",
          "id" : "MAC-ID",
          "name" : "My Mac"
        },
        {
          "platform" : "iOS Simulator",
          "id" : "11111111-1111-1111-1111-111111111111",
          "OS" : "18.4",
          "name" : "iPhone 16"
        },
        {
          "platform" : "iOS",
          "id" : "dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder",
          "name" : "Any iOS Device"
        }
      ]
    }
    """
}

private final class FakeXcodebuildRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executablePath: String
        let arguments: [String]
        let workingDirectory: String?
        let deadline: Date?
    }

    private(set) var invocations: [Invocation] = []
    var listJSON = "{}"
    var testPlanJSON = #"{"testPlans":[]}"#
    var destinationJSON = #"{"destinations":[]}"#
    var listError: Error?
    var destinationError: Error?
    var fallbackWithoutJSON = false

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        let invocation = Invocation(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            deadline: deadline
        )
        invocations.append(invocation)
        if arguments.contains("-list") {
            if let listError { throw listError }
            return ProcessResult(exitCode: 0, standardOutput: listJSON, standardError: "")
        }
        if arguments.contains("-showTestPlans") {
            if arguments.contains("-json") || !fallbackWithoutJSON {
                return ProcessResult(exitCode: 0, standardOutput: testPlanJSON, standardError: "")
            }
            return ProcessResult(exitCode: 64, standardOutput: "", standardError: "invalid option '-json'")
        }
        if arguments.contains("-showdestinations") {
            if let destinationError { throw destinationError }
            if arguments.contains("-json") || !fallbackWithoutJSON {
                return ProcessResult(exitCode: 0, standardOutput: destinationJSON, standardError: "")
            }
            return ProcessResult(exitCode: 64, standardOutput: "", standardError: "invalid option '-json'")
        }
        return ProcessResult(exitCode: 1, standardOutput: "", standardError: "unexpected arguments")
    }
}

private extension IOSLookup<[IOSSimulatorDestination]> {
    var udids: [String] {
        if case .succeeded(let devices) = self { return devices.map(\.udid) }
        return []
    }
}
