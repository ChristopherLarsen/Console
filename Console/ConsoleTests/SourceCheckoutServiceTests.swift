import XCTest
@testable import Console

final class SourceCheckoutServiceTests: XCTestCase {

    // MARK: - Fakes

    /// Records every invocation and can simulate git side effects. Never runs real git.
    private final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {

        struct Invocation: Equatable {
            let executablePath: String
            let arguments: [String]
            let workingDirectory: String?
        }

        private(set) var invocations: [Invocation] = []
        var exitCode: Int32 = 0
        var standardOutput = ""
        var standardError = ""
        /// Called before returning; lets a test simulate the effect of the command.
        var sideEffect: ((Invocation) -> Void)?

        func run(executablePath: String,
                 arguments: [String],
                 workingDirectory: String?,
                 deadline: Date?) async throws -> ProcessResult {
            let invocation = Invocation(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
            invocations.append(invocation)
            sideEffect?(invocation)
            _ = deadline
            return ProcessResult(
                exitCode: exitCode,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }

        var cloneArguments: [String]? {
            invocations.first(where: { $0.arguments.first == "clone" })?.arguments
        }
    }

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceCheckoutServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func plantXcodeProject(in checkoutPath: String) {
        try? FileManager.default.createDirectory(
            atPath: checkoutPath + "/Console/Console.xcodeproj",
            withIntermediateDirectories: true
        )
    }

    private func makeService(runner: FakeProcessRunner) -> SourceCheckoutService {
        SourceCheckoutService(
            repositoryURL: "https://github.com/ChristopherLarsen/Console.git",
            destinationRoot: workDirectory.path + "/ConsoleUpdates",
            processRunner: runner
        )
    }

    // MARK: - Destination layout

    func testDestinationPathUsesTagAndManagedRoot() {
        let service = makeService(runner: FakeProcessRunner())
        XCTAssertEqual(service.destinationPath(for: "v1.2.3"), workDirectory.path + "/ConsoleUpdates/Console-v1.2.3")
        XCTAssertNil(service.destinationPath(for: "1.2"))
        XCTAssertNil(service.destinationPath(for: "../../evil"))
    }

    // MARK: - Fresh clone

    func testPrepareClonesExactTagWithArgvArray() async throws {
        let runner = FakeProcessRunner()
        // Simulate git clone creating the staging directory.
        runner.sideEffect = { invocation in
            guard invocation.arguments.first == "clone",
                  let destination = invocation.arguments.last else { return }
            try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                atPath: destination + "/Console/Console.xcodeproj",
                withIntermediateDirectories: true
            )
        }

        let service = makeService(runner: runner)
        let prepared = try await service.prepare(tag: "v1.3.0")

        XCTAssertEqual(prepared.directoryPath, workDirectory.path + "/ConsoleUpdates/Console-v1.3.0")
        XCTAssertEqual(prepared.xcodeProjectPath, prepared.directoryPath + "/Console/Console.xcodeproj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.directoryPath))

        let cloneArgs = try XCTUnwrap(runner.cloneArguments)
        // argv array, never an interpolated shell string.
        XCTAssertEqual(cloneArgs.first, "clone")
        XCTAssertEqual(cloneArgs.count, 8)
        XCTAssertTrue(cloneArgs.contains("--depth"))
        XCTAssertTrue(cloneArgs.contains("1"))
        XCTAssertEqual(cloneArgs[3], "--single-branch")
        XCTAssertEqual(cloneArgs[4], "--branch")
        XCTAssertEqual(cloneArgs[5], "v1.3.0")
        XCTAssertEqual(cloneArgs[6], "https://github.com/ChristopherLarsen/Console.git")
        XCTAssertTrue(
            cloneArgs[7].hasPrefix(prepared.directoryPath + ".staging-"),
            "clone targets a staging sibling: \(cloneArgs[7])"
        )
        for argument in cloneArgs {
            XCTAssertFalse(argument.contains(" && "), "arguments must never contain shell operators")
        }

        let verify = runner.invocations.first { $0.arguments.first == "-C" }
        XCTAssertNil(verify, "no verification call should be needed for a fresh clone")

        for invocation in runner.invocations {
            XCTAssertEqual(invocation.executablePath, "/usr/bin/git")
        }
    }

    func testFailedCloneLeavesNoStagingOrDestinationBehind() async {
        let runner = FakeProcessRunner()
        runner.exitCode = 128
        runner.standardError = "fatal: Remote branch not found"

        let service = makeService(runner: runner)

        do {
            _ = try await service.prepare(tag: "v9.9.9")
            XCTFail("Expected command failure")
        } catch let error as SourceCheckoutError {
            guard case .commandFailed(_, _, let stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(stderr.contains("Remote branch not found"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path + "/ConsoleUpdates")) ?? []
        XCTAssertTrue(contents.isEmpty, "staging directory must be cleaned up after failure")
    }

    // MARK: - Existing checkout handling

    func testPrepareReusesExistingCheckoutHoldingTheTag() async throws {
        let runner = FakeProcessRunner()
        runner.standardOutput = "aaa111\naaa111\n"
        let service = makeService(runner: runner)
        let destination = try XCTUnwrap(service.destinationPath(for: "v1.2.3"))

        try FileManager.default.createDirectory(atPath: destination + "/.git", withIntermediateDirectories: true)
        plantXcodeProject(in: destination)

        let prepared = try await service.prepare(tag: "v1.2.3")

        XCTAssertEqual(prepared.directoryPath, destination)
        XCTAssertEqual(prepared.xcodeProjectPath, destination + "/Console/Console.xcodeproj")
        XCTAssertNil(runner.cloneArguments, "an existing valid checkout is reused without cloning")
        XCTAssertEqual(
            runner.invocations.first?.arguments.first,
            "-C",
            "existing checkouts are verified in-place"
        )
    }

    func testPrepareRejectsExistingCheckoutWhoseHeadDiffersFromTag() async {
        let runner = FakeProcessRunner()
        runner.standardOutput = "aaa111\nbbb222\n"
        let service = makeService(runner: runner)
        let destination = workDirectory.path + "/ConsoleUpdates/Console-v1.2.6"

        try? FileManager.default.createDirectory(atPath: destination + "/.git", withIntermediateDirectories: true)
        plantXcodeProject(in: destination)

        do {
            _ = try await service.prepare(tag: "v1.2.6")
            XCTFail("Expected destinationExists failure")
        } catch let error as SourceCheckoutError {
            XCTAssertEqual(error, .destinationExists(destination))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertNil(runner.cloneArguments, "a HEAD/tag mismatch must not trigger a clone")
    }

    func testPrepareRejectsExistingCheckoutWithUnresolvableHEAD() async {
        let runner = FakeProcessRunner()
        runner.exitCode = 128
        runner.standardOutput = ""
        let service = makeService(runner: runner)
        let destination = workDirectory.path + "/ConsoleUpdates/Console-v1.2.7"

        try? FileManager.default.createDirectory(atPath: destination + "/.git", withIntermediateDirectories: true)
        plantXcodeProject(in: destination)

        do {
            _ = try await service.prepare(tag: "v1.2.7")
            XCTFail("Expected destinationExists failure")
        } catch let error as SourceCheckoutError {
            XCTAssertEqual(error, .destinationExists(destination))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPrepareRejectsExistingFolderWithoutValidCheckout() async {
        let runner = FakeProcessRunner()
        runner.exitCode = 128
        let service = makeService(runner: runner)
        let destination = workDirectory.path + "/ConsoleUpdates/Console-v1.2.4"

        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        do {
            _ = try await service.prepare(tag: "v1.2.4")
            XCTFail("Expected destinationExists failure")
        } catch let error as SourceCheckoutError {
            XCTAssertEqual(error, .destinationExists(destination))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPrepareRejectsExistingValidTagWithoutXcodeProject() async {
        let runner = FakeProcessRunner()
        let service = makeService(runner: runner)
        let destination = workDirectory.path + "/ConsoleUpdates/Console-v1.2.5"

        try? FileManager.default.createDirectory(atPath: destination + "/.git", withIntermediateDirectories: true)

        do {
            _ = try await service.prepare(tag: "v1.2.5")
            XCTFail("Expected destinationExists failure")
        } catch let error as SourceCheckoutError {
            XCTAssertEqual(error, .destinationExists(destination))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination), "existing folder must be left untouched")
        XCTAssertNil(runner.cloneArguments)
    }

    func testPrepareRejectsCloneMissingXcodeProjectAndLeavesNoDestination() async {
        let runner = FakeProcessRunner()
        runner.sideEffect = { invocation in
            guard invocation.arguments.first == "clone",
                  let destination = invocation.arguments.last else { return }
            try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        }

        let service = makeService(runner: runner)

        do {
            _ = try await service.prepare(tag: "v1.4.0")
            XCTFail("Expected missingXcodeProject failure")
        } catch let error as SourceCheckoutError {
            XCTAssertEqual(error, .missingXcodeProject)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workDirectory.path + "/ConsoleUpdates/Console-v1.4.0"),
            "destination must not be created when the project is missing"
        )
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path + "/ConsoleUpdates")) ?? []
        XCTAssertTrue(contents.isEmpty, "staging directory must be cleaned up after missing-project failure")
    }

    // MARK: - Tag safety

    func testPrepareRefusesInvalidTagsBeforeTouchingGit() async {
        let runner = FakeProcessRunner()
        let service = makeService(runner: runner)

        do {
            _ = try await service.prepare(tag: "main; rm -rf ~")
            XCTFail("Expected invalid tag failure")
        } catch let error as SourceCheckoutError {
            XCTAssertEqual(error, .invalidTag("main; rm -rf ~"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertTrue(runner.invocations.isEmpty, "git must never run for malformed tags")
    }
}
