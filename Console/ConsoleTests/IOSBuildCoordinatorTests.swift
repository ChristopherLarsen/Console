import XCTest
@testable import Console

@MainActor
final class IOSBuildCoordinatorTests: XCTestCase {

    private var tmpRoot: URL!
    private var runner: FakeBuildProcessRunner!
    private var parser: FakeResultParser!
    private var coordinator: IOSBuildCoordinator!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 15
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        runner = FakeBuildProcessRunner()
        parser = FakeResultParser()
        coordinator = makeCoordinator()
    }

    override func tearDownWithError() throws {
        if let coordinator {
            for job in coordinator.jobs where !job.state.isTerminal {
                coordinator.cancel(job.id)
            }
        }
        runner?.releaseAll()
        try? FileManager.default.removeItem(at: tmpRoot)
        coordinator = nil
        runner = nil
        parser = nil
    }

    // MARK: - Argv

    func testBuildArgvUsesStructuredXcodebuildAndSpacedPaths() throws {
        let profile = sampleProfile(
            projectPath: "/tmp/My App/App.xcodeproj",
            scheme: "My Scheme",
            configuration: "Debug"
        )
        let bundle = URL(fileURLWithPath: "/tmp/jobs/A.xcresult")
        let spec = try IOSXcodebuildCommand.makeLaunchSpec(
            kind: .build,
            profile: profile,
            selection: nil,
            resultBundleURL: bundle,
            timeouts: .default
        )

        XCTAssertEqual(spec.executablePath, "/usr/bin/xcodebuild")
        XCTAssertEqual(spec.workingDirectory, "/tmp/My App")
        XCTAssertEqual(spec.arguments.first, "build")
        XCTAssertEqual(value(after: "-project", in: spec.arguments), "/tmp/My App/App.xcodeproj")
        XCTAssertEqual(value(after: "-scheme", in: spec.arguments), "My Scheme")
        XCTAssertEqual(value(after: "-configuration", in: spec.arguments), "Debug")
        XCTAssertEqual(value(after: "-destination", in: spec.arguments), "platform=iOS Simulator,id=SIM-1")
        XCTAssertEqual(value(after: "-resultBundlePath", in: spec.arguments), bundle.path)
        XCTAssertFalse(spec.arguments.contains("test"))
        XCTAssertFalse(spec.arguments.contains("-testPlan"))
        XCTAssertFalse(spec.arguments.contains { $0.hasPrefix("-only-testing") })
        assertNoShellOrSigning(spec)
    }

    func testWorkspaceBuildUsesWorkspaceFlag() throws {
        let profile = sampleProfile(projectPath: "/tmp/App.xcworkspace")
        let spec = try IOSXcodebuildCommand.makeLaunchSpec(
            kind: .build,
            profile: profile,
            selection: nil,
            resultBundleURL: URL(fileURLWithPath: "/tmp/a.xcresult"),
            timeouts: .default
        )
        XCTAssertEqual(value(after: "-workspace", in: spec.arguments), "/tmp/App.xcworkspace")
        XCTAssertNil(spec.arguments.firstIndex(of: "-project"))
    }

    func testSelectedTestsRequireExplicitIdentifiersOrTestPlan() {
        let profile = sampleProfile(testPlan: nil)
        XCTAssertThrowsError(
            try IOSXcodebuildCommand.makeLaunchSpec(
                kind: .runSelectedTests,
                profile: profile,
                selection: IOSTestSelection(),
                resultBundleURL: URL(fileURLWithPath: "/tmp/a.xcresult"),
                timeouts: .default
            )
        ) { error in
            XCTAssertEqual(error as? IOSBuildRequestError, .missingTestSelection)
        }

        XCTAssertThrowsError(
            try coordinator.submitSelectedTests(profile: profile, identifiers: ["  ", ""])
        ) { error in
            XCTAssertEqual(error as? IOSBuildRequestError, .missingTestSelection)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    func testSelectedTestsArgvIncludesTimeoutFlagsAndOnlyTesting() throws {
        var timeouts = IOSBuildTimeouts.default
        timeouts.test = 90
        timeouts.maximumTestExecutionTimeAllowance = 45
        timeouts.defaultTestExecutionTimeAllowance = 12
        let selection = IOSTestSelection(identifiers: ["AppTests/LoginTests"], testPlan: "Unit")
        let spec = try IOSXcodebuildCommand.makeLaunchSpec(
            kind: .runSelectedTests,
            profile: sampleProfile(),
            selection: selection,
            resultBundleURL: URL(fileURLWithPath: "/tmp/t.xcresult"),
            timeouts: timeouts
        )

        XCTAssertEqual(spec.arguments.first, "test")
        XCTAssertEqual(value(after: "-testPlan", in: spec.arguments), "Unit")
        XCTAssertTrue(spec.arguments.contains("-only-testing:AppTests/LoginTests"))
        XCTAssertFalse(spec.arguments.contains { $0.contains("UITest") })
        XCTAssertEqual(value(after: "-test-timeouts-enabled", in: spec.arguments), "YES")
        XCTAssertEqual(value(after: "-maximum-test-execution-time-allowance", in: spec.arguments), "45")
        XCTAssertEqual(value(after: "-default-test-execution-time-allowance", in: spec.arguments), "12")
        assertNoShellOrSigning(spec)
    }

    func testProfileTestPlanIsEnoughSelectionAndDoesNotAddOnlyTesting() async throws {
        let profile = sampleProfile(testPlan: "Unit")
        let id = try coordinator.submitSelectedTests(profile: profile)
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(job.testSelection?.testPlan, "Unit")
        XCTAssertEqual(job.testSelection?.identifiers, [])
        let args = try XCTUnwrap(runner.invocations.first).arguments
        XCTAssertEqual(value(after: "-testPlan", in: args), "Unit")
        XCTAssertFalse(args.contains { $0.hasPrefix("-only-testing") })
    }

    // MARK: - Job states

    func testSuccessfulBuildRecordsExitCodeBundlePathAndParsedSummary() async throws {
        runner.result = ProcessResult(
            exitCode: 0,
            standardOutput: "BUILD SUCCEEDED\nAll tests passed",
            standardError: ""
        )
        let profile = sampleProfile()
        let id = try coordinator.submitBuild(profile: profile)
        var mutated = profile
        mutated.scheme = "Other"
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(job.kind, .build)
        XCTAssertEqual(job.exitCode, 0)
        XCTAssertEqual(job.profile.scheme, "App")
        let waited = await coordinator.wait(for: id)
        XCTAssertEqual(waited.state, .succeeded)
        XCTAssertEqual(waited.id, id)
        XCTAssertNotEqual(job.profile.scheme, mutated.scheme)
        XCTAssertEqual(job.resultBundleURL.pathExtension, "xcresult")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.resultBundleURL.path))
        XCTAssertTrue(job.output.contains("BUILD SUCCEEDED"))
        XCTAssertNotNil(job.startedAt)
        XCTAssertNotNil(job.finishedAt)
        XCTAssertGreaterThanOrEqual(job.finishedAt ?? .distantPast, job.startedAt ?? .distantFuture)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations[0].executablePath, "/usr/bin/xcodebuild")
        XCTAssertEqual(
            value(after: "-resultBundlePath", in: runner.invocations[0].arguments),
            job.resultBundleURL.path
        )
        XCTAssertEqual(parser.calls.count, 1)
        XCTAssertEqual(parser.calls[0].bundleURL, job.resultBundleURL)
        XCTAssertEqual(parser.calls[0].jobKind, .build)
        XCTAssertEqual(job.resultSummary?.parseStatus, .parsed)
        XCTAssertFalse(job.resultSummary?.recordsIndicateFailure ?? true)
    }

    func testCompileFailureIsFailedEvenWhenOutputLooksSuccessful() async throws {
        runner.result = ProcessResult(
            exitCode: 65,
            standardOutput: "BUILD SUCCEEDED\n0 tests failed",
            standardError: "error: compile failed"
        )
        let id = try coordinator.submitBuild(profile: sampleProfile())
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.exitCode, 65)
        XCTAssertTrue(job.output.contains("compile failed"))
        XCTAssertTrue(job.output.contains("BUILD SUCCEEDED"))
        XCTAssertEqual(parser.calls.count, 1)
        XCTAssertEqual(job.resultSummary?.parseStatus, .parsed)
    }

    func testFailingSelectedTestIsFailedFromExitCode() async throws {
        runner.result = ProcessResult(
            exitCode: 65,
            standardOutput: "TEST SUCCEEDED\nAll tests passed",
            standardError: ""
        )
        let id = try coordinator.submitSelectedTests(
            profile: sampleProfile(),
            identifiers: ["AppTests/LoginTests/testLogin"]
        )
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.kind, .runSelectedTests)
        XCTAssertEqual(job.exitCode, 65)
        XCTAssertEqual(job.testSelection?.identifiers, ["AppTests/LoginTests/testLogin"])
        let args = try XCTUnwrap(runner.invocations.first).arguments
        XCTAssertTrue(args.contains("-only-testing:AppTests/LoginTests/testLogin"))
        XCTAssertFalse(args.contains { $0.contains("UITest") || $0.contains("ConsoleUITests") })
    }

    func testCancellationOfRunningJob() async throws {
        runner.hold = true
        let id = try coordinator.submitBuild(profile: sampleProfile())
        try await waitUntil { self.coordinator.job(id: id)?.state == .running }
        coordinator.cancel(id)
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .cancelled)
        XCTAssertNil(job.exitCode)
        XCTAssertNotNil(job.errorMessage)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testStopAfterProcessExitDuringParseMarksJobCancelled() async throws {
        runner.hold = true
        parser.parseDelaySeconds = 0.4
        let id = try coordinator.submitBuild(profile: sampleProfile())
        try await waitUntil { self.coordinator.job(id: id)?.state == .running }
        try await waitUntil { self.runner.invocations.count == 1 }
        runner.releaseOne()
        try await waitUntil { self.runner.returnedRuns == 1 }
        // The fake process has exited; parsing is still in flight. Stop here.
        coordinator.cancel(id)
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .cancelled)
        XCTAssertNil(job.exitCode)
        XCTAssertFalse(job.output.contains("BUILD SUCCEEDED"))
    }

    func testTimeoutMapsToTimedOutAndDoesNotUseOutputWording() async throws {
        runner.error = ProcessRunError.timedOut
        runner.result = ProcessResult(exitCode: 0, standardOutput: "BUILD SUCCEEDED", standardError: "")
        let id = try coordinator.submitBuild(profile: sampleProfile())
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .timedOut)
        XCTAssertNil(job.exitCode)
        XCTAssertEqual(job.errorMessage, ProcessRunError.timedOut.localizedDescription)
    }

    func testTwoQueuedBuildsSerializeAndUseDistinctResultBundles() async throws {
        runner.hold = true
        let first = try coordinator.submitBuild(profile: sampleProfile(scheme: "App"))
        let second = try coordinator.submitBuild(profile: sampleProfile(scheme: "AppTests"))
        try await waitUntil { self.coordinator.job(id: first)?.state == .running }

        XCTAssertEqual(coordinator.job(id: first)?.state, .running)
        XCTAssertEqual(coordinator.job(id: second)?.state, .queued)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(value(after: "-scheme", in: runner.invocations[0].arguments), "App")

        runner.releaseOne()
        let finishedFirst = try await waitForJob(first)
        try await waitUntil { self.coordinator.job(id: second)?.state == .running }

        XCTAssertEqual(finishedFirst.state, .succeeded)
        XCTAssertEqual(coordinator.job(id: second)?.state, .running)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(value(after: "-scheme", in: runner.invocations[1].arguments), "AppTests")

        runner.releaseOne()
        let finishedSecond = try await waitForJob(second)

        XCTAssertEqual(finishedSecond.state, .succeeded)
        XCTAssertNotEqual(finishedFirst.resultBundleURL, finishedSecond.resultBundleURL)
        XCTAssertEqual(finishedFirst.profile.scheme, "App")
        XCTAssertEqual(finishedSecond.profile.scheme, "AppTests")
        XCTAssertEqual(Set(runner.invocations.map(\.executablePath)), ["/usr/bin/xcodebuild"])
    }

    func testQueuedJobCanBeCancelledWithoutLaunching() async throws {
        runner.hold = true
        let first = try coordinator.submitBuild(profile: sampleProfile())
        let second = try coordinator.submitBuild(profile: sampleProfile())
        try await waitUntil { self.coordinator.job(id: first)?.state == .running }

        coordinator.cancel(second)
        XCTAssertEqual(coordinator.job(id: second)?.state, .cancelled)

        runner.releaseOne()
        _ = try await waitForJob(first)
        let cancelled = try await waitForJob(second)

        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testMissingBundleKeepsExitSuccessAndRecordsParseStatus() async throws {
        parser.summary = .unparsed(.missingBundle, message: "missing")
        runner.result = ProcessResult(exitCode: 0, standardOutput: "BUILD SUCCEEDED", standardError: "")
        let missingID = try coordinator.submitBuild(profile: sampleProfile())
        let missing = try await waitForJob(missingID)

        XCTAssertEqual(missing.state, .succeeded)
        XCTAssertEqual(missing.exitCode, 0)
        XCTAssertEqual(missing.resultSummary?.parseStatus, .missingBundle)
        XCTAssertFalse(missing.resultSummary?.recordsIndicateFailure ?? true)
        XCTAssertEqual(parser.calls.count, 1)
        XCTAssertEqual(parser.calls[0].bundleURL, missing.resultBundleURL)
    }

    func testMalformedJSONDoesNotPromoteFailureToSuccess() async throws {
        parser.summary = .unparsed(.schemaMismatch, message: "malformed JSON")
        runner.result = ProcessResult(
            exitCode: 65,
            standardOutput: "TEST SUCCEEDED\nAll tests passed",
            standardError: ""
        )
        let malformedID = try coordinator.submitBuild(profile: sampleProfile())
        let malformed = try await waitForJob(malformedID)

        XCTAssertEqual(malformed.state, .failed)
        XCTAssertEqual(malformed.exitCode, 65)
        XCTAssertEqual(malformed.resultSummary?.parseStatus, .schemaMismatch)
        XCTAssertFalse(malformed.resultSummary?.recordsIndicateFailure ?? true)
    }

    func testParsedTestFailureOverridesZeroExitAndIgnoresLogWording() async throws {
        parser.summary = .parsed(
            outcome: .failed,
            issues: [
                IOSResultIssue(
                    kind: .testFailure,
                    message: "XCTAssertEqual failed",
                    fileURL: URL(fileURLWithPath: "/tmp/App/LoginTests.swift"),
                    line: 42,
                    testIdentifier: "AppTests/LoginTests/testLogin"
                )
            ],
            failedTestCount: 1
        )
        runner.result = ProcessResult(
            exitCode: 0,
            standardOutput: "TEST SUCCEEDED\nAll tests passed",
            standardError: ""
        )
        let id = try coordinator.submitSelectedTests(
            profile: sampleProfile(),
            identifiers: ["AppTests/LoginTests/testLogin"]
        )
        let job = try await waitForJob(id)

        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.exitCode, 0)
        XCTAssertEqual(job.errorMessage, "The result bundle reported failures.")
        XCTAssertEqual(job.resultSummary?.issues.first?.testIdentifier, "AppTests/LoginTests/testLogin")
        XCTAssertTrue(job.output.contains("TEST SUCCEEDED"))
    }

    func testQueuedCancelDoesNotParseResults() async throws {
        runner.hold = true
        let first = try coordinator.submitBuild(profile: sampleProfile())
        let second = try coordinator.submitBuild(profile: sampleProfile())
        try await waitUntil { self.coordinator.job(id: first)?.state == .running }

        coordinator.cancel(second)
        XCTAssertEqual(coordinator.job(id: second)?.state, .cancelled)
        XCTAssertNil(coordinator.job(id: second)?.resultSummary)
        XCTAssertTrue(parser.calls.allSatisfy { $0.bundleURL != coordinator.job(id: second)?.resultBundleURL })

        runner.releaseOne()
        _ = try await waitForJob(first)
        let cancelled = try await waitForJob(second)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.resultSummary)
    }

    func testConfigurableTimeoutsArePassedAsDeadlineAndTestFlags() async throws {
        var timeouts = IOSBuildTimeouts.default
        timeouts.build = 12
        timeouts.test = 34
        timeouts.maximumTestExecutionTimeAllowance = 21
        timeouts.defaultTestExecutionTimeAllowance = 8
        coordinator = makeCoordinator(timeouts: timeouts)

        let beforeBuild = Date()
        let buildID = try coordinator.submitBuild(profile: sampleProfile())
        _ = try await waitForJob(buildID)
        let buildDeadline = try XCTUnwrap(runner.invocations.last?.deadline)
        XCTAssertEqual(buildDeadline.timeIntervalSince(beforeBuild), 12, accuracy: 2)

        let beforeTest = Date()
        let testID = try coordinator.submitSelectedTests(
            profile: sampleProfile(),
            identifiers: ["AppTests"]
        )
        _ = try await waitForJob(testID)
        let testInvocation = try XCTUnwrap(runner.invocations.last)
        let testDeadline = try XCTUnwrap(testInvocation.deadline)
        XCTAssertEqual(testDeadline.timeIntervalSince(beforeTest), 34, accuracy: 2)
        XCTAssertEqual(value(after: "-maximum-test-execution-time-allowance", in: testInvocation.arguments), "21")
        XCTAssertEqual(value(after: "-default-test-execution-time-allowance", in: testInvocation.arguments), "8")
        XCTAssertEqual(value(after: "-test-timeouts-enabled", in: testInvocation.arguments), "YES")
    }

    func testBuildUsesSnapshotEvenIfCallerMutatesProfileLater() async throws {
        var profile = sampleProfile(scheme: "Snap")
        runner.hold = true
        let id = try coordinator.submitBuild(profile: profile)
        profile.scheme = "Mutated"
        try await waitUntil { self.coordinator.job(id: id)?.state == .running }
        XCTAssertEqual(coordinator.job(id: id)?.profile.scheme, "Snap")
        XCTAssertEqual(value(after: "-scheme", in: runner.invocations[0].arguments), "Snap")
        runner.releaseOne()
        let job = try await waitForJob(id)
        XCTAssertEqual(job.profile.scheme, "Snap")
    }

    func testBoundedOutputIsPreservedFromProcessResult() async throws {
        runner.result = ProcessResult(
            exitCode: 1,
            standardOutput: "stdout-body",
            standardError: "stderr-body",
            standardOutputTruncated: true,
            standardErrorTruncated: false,
            standardOutputByteCount: 2_000_000,
            standardErrorByteCount: 11
        )
        let id = try coordinator.submitBuild(profile: sampleProfile())
        let job = try await waitForJob(id)
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.outputTruncated)
        XCTAssertTrue(job.standardOutput.contains("truncated"))
        XCTAssertTrue(job.standardError.contains("stderr-body"))
    }

    // MARK: - Helpers

    private func makeCoordinator(timeouts: IOSBuildTimeouts = .default) -> IOSBuildCoordinator {
        IOSBuildCoordinator(
            processRunner: runner,
            resultParser: parser,
            timeouts: timeouts,
            resultsDirectory: tmpRoot
        )
    }

    private func sampleProfile(
        projectPath: String = "/tmp/App.xcodeproj",
        scheme: String? = "App",
        configuration: String? = "Debug",
        testPlan: String? = nil,
        simulatorUDID: String? = "SIM-1"
    ) -> IOSProjectProfile {
        IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: projectPath,
            scheme: scheme,
            configuration: configuration,
            testPlan: testPlan,
            simulatorUDID: simulatorUDID
        )
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

    private func waitUntil(
        seconds: TimeInterval = 8,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout(seconds: seconds)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func assertNoShellOrSigning(_ spec: ProcessLaunchSpec) {
        XCTAssertEqual(spec.executablePath, "/usr/bin/xcodebuild")
        XCTAssertFalse(spec.executablePath.contains("zsh"))
        XCTAssertFalse(spec.arguments.contains("-c"))
        XCTAssertFalse(spec.arguments.contains("zsh"))
        let joined = spec.arguments.joined(separator: " ")
        XCTAssertFalse(joined.contains("CODE_SIGN"))
        XCTAssertFalse(joined.contains("PROVISIONING"))
        XCTAssertFalse(joined.contains("allowProvisioning"))
        XCTAssertFalse(spec.arguments.contains("-exportArchive"))
        XCTAssertFalse(spec.arguments.contains("-allowProvisioningUpdates"))
    }

    private struct TestTimeout: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Test exceeded \(seconds)s hard timeout" }
    }
}

private final class FakeBuildProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executablePath: String
        var arguments: [String]
        var workingDirectory: String?
        var deadline: Date?
    }

    private let lock = NSLock()
    private var invocationsStorage: [Invocation] = []
    private var releasedCount = 0
    private var returnedRunsStorage = 0
    private var stopHolds = false

    var hold = false
    var result = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    var error: Error?
    var writeBundleData: Data?

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocationsStorage
    }

    var returnedRuns: Int {
        lock.lock()
        defer { lock.unlock() }
        return returnedRunsStorage
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
        let invocation = Invocation(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            deadline: deadline
        )
        lock.lock()
        invocationsStorage.append(invocation)
        let shouldHold = hold
        lock.unlock()

        if shouldHold {
            let holdDeadline = Date().addingTimeInterval(8)
            var released = false
            while Date() < holdDeadline {
                if Task.isCancelled {
                    throw ProcessRunError.cancelled
                }
                lock.lock()
                let stopped = stopHolds
                if releasedCount > 0 {
                    releasedCount -= 1
                    released = true
                }
                lock.unlock()
                if stopped {
                    throw ProcessRunError.cancelled
                }
                if released { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if Task.isCancelled {
                throw ProcessRunError.cancelled
            }
            if !released {
                throw ProcessRunError.timedOut
            }
        }

        if Task.isCancelled {
            throw ProcessRunError.cancelled
        }

        if let writeBundleData {
            if let index = arguments.firstIndex(of: "-resultBundlePath"), index + 1 < arguments.count {
                let url = URL(fileURLWithPath: arguments[index + 1])
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? writeBundleData.write(to: url)
            }
        }

        if let error {
            lock.lock()
            returnedRunsStorage += 1
            lock.unlock()
            throw error
        }
        lock.lock()
        returnedRunsStorage += 1
        lock.unlock()
        return result
    }
}

private final class FakeResultParser: IOSResultParsing, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var bundleURL: URL
        var jobKind: IOSBuildJobKind
    }

    private let lock = NSLock()
    private var callsStorage: [Call] = []
    var summary = IOSResultSummary.parsed(outcome: .succeeded, issues: [])
    var parseDelaySeconds: TimeInterval = 0

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    func parseBundle(at url: URL, jobKind: IOSBuildJobKind) async -> IOSResultSummary {
        lock.lock()
        callsStorage.append(Call(bundleURL: url, jobKind: jobKind))
        let summary = self.summary
        let delay = parseDelaySeconds
        lock.unlock()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return summary
    }
}
