import XCTest
@testable import Console

@MainActor
final class IOSBuildJobViewTests: XCTestCase {

    private var tmpRoot: URL!
    private var opener: RecordingIOSWorkspaceOpener!
    private var pasteboard: RecordingIOSPasteboard!
    private var existingBundles: Set<String>!
    private var model: IOSBuildJobPanelModel!
    private var runner: FakeJobProcessRunner!
    private var parser: FakeJobResultParser!
    private var coordinator: IOSBuildCoordinator!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 15
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-job-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        opener = RecordingIOSWorkspaceOpener()
        pasteboard = RecordingIOSPasteboard()
        existingBundles = []
        model = makeModel()
        runner = FakeJobProcessRunner()
        parser = FakeJobResultParser()
        coordinator = IOSBuildCoordinator(
            processRunner: runner,
            resultParser: parser,
            resultsDirectory: tmpRoot
        )
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
        model = nil
        opener = nil
        pasteboard = nil
    }

    // MARK: - Presentation states

    func testSuccessfulBuildPresentation() {
        let bundle = plantBundle("ok")
        let job = makeJob(
            state: .succeeded,
            kind: .build,
            exitCode: 0,
            output: "BUILD SUCCEEDED\nAll tests passed",
            resultBundleURL: bundle,
            summary: .parsed(outcome: .succeeded, issues: [])
        )
        let presentation = present(job)

        XCTAssertEqual(presentation.state, .succeeded)
        XCTAssertEqual(presentation.stateTitle, "Succeeded")
        XCTAssertFalse(presentation.isInProgress)
        XCTAssertFalse(presentation.canStop)
        XCTAssertTrue(presentation.canOpenResult)
        XCTAssertFalse(presentation.canOpenSource)
        XCTAssertFalse(presentation.canCopyError)
        XCTAssertFalse(presentation.canRerunFailedTests)
        XCTAssertNil(presentation.firstIssueText)
        XCTAssertNil(presentation.diagnosticText)
        XCTAssertTrue(presentation.output.contains("BUILD SUCCEEDED"))
        XCTAssertEqual(presentation.resultURL, bundle)
    }

    func testCompileFailurePresentationAndOpenSource() {
        let source = URL(fileURLWithPath: "/tmp/App/ContentView.swift")
        let bundle = plantBundle("compile")
        let job = makeJob(
            state: .failed,
            kind: .build,
            exitCode: 65,
            output: "BUILD SUCCEEDED\nerror: cannot find type",
            errorMessage: nil,
            resultBundleURL: bundle,
            summary: .parsed(
                outcome: .failed,
                issues: [
                    IOSResultIssue(
                        kind: .buildError,
                        message: "cannot find type 'Foo'",
                        fileURL: source,
                        line: 12,
                        testIdentifier: nil
                    )
                ]
            )
        )
        let presentation = present(job)

        XCTAssertEqual(presentation.state, .failed)
        XCTAssertTrue(presentation.firstIssueText?.contains("ContentView.swift:12") == true)
        XCTAssertTrue(presentation.firstIssueText?.contains("cannot find type") == true)
        XCTAssertEqual(presentation.sourceURL, source)
        XCTAssertEqual(presentation.resultURL, bundle)
        XCTAssertTrue(presentation.canOpenSource)
        XCTAssertTrue(presentation.canOpenResult)
        XCTAssertTrue(presentation.canCopyError)
        XCTAssertFalse(presentation.canRerunFailedTests)
        XCTAssertEqual(presentation.errorCopyText, "cannot find type 'Foo'")

        model.openSource(job: job)
        XCTAssertEqual(opener.opened, [source])
        model.openResult(job: job)
        XCTAssertEqual(opener.opened, [source, bundle])
        XCTAssertTrue(opener.opened.allSatisfy { $0.isFileURL })
    }

    func testFailingSelectedTestPresentation() {
        let source = URL(fileURLWithPath: "/tmp/App/LoginTests.swift")
        let job = makeJob(
            state: .failed,
            kind: .runSelectedTests,
            exitCode: 65,
            output: "TEST SUCCEEDED\nConsoleUITests/testSmoke",
            resultBundleURL: plantBundle("test"),
            testSelection: IOSTestSelection(
                identifiers: [
                    "AppTests/LoginTests/testLogin",
                    "AppTests/LoginTests/testLogout",
                    "ConsoleUITests/Smoke"
                ]
            ),
            summary: .parsed(
                outcome: .failed,
                issues: [
                    IOSResultIssue(
                        kind: .testFailure,
                        message: "XCTAssertEqual failed",
                        fileURL: source,
                        line: 42,
                        testIdentifier: "AppTests/LoginTests/testLogin"
                    )
                ],
                failedTestCount: 1
            )
        )
        let presentation = present(job)

        XCTAssertEqual(presentation.state, .failed)
        XCTAssertEqual(presentation.kindTitle, "Selected Tests")
        XCTAssertEqual(presentation.sourceURL, source)
        XCTAssertEqual(presentation.failedTestIdentifiers, ["AppTests/LoginTests/testLogin"])
        XCTAssertTrue(presentation.canRerunFailedTests)
        XCTAssertFalse(presentation.failedTestIdentifiers.contains("AppTests/LoginTests/testLogout"))
        XCTAssertFalse(presentation.failedTestIdentifiers.contains("ConsoleUITests/Smoke"))
        XCTAssertFalse(presentation.failedTestIdentifiers.contains { $0.contains("UITest") })
    }

    func testCancellationPresentation() {
        let job = makeJob(
            state: .cancelled,
            errorMessage: "The job was cancelled."
        )
        let presentation = present(job)
        XCTAssertEqual(presentation.stateTitle, "Cancelled")
        XCTAssertFalse(presentation.canStop)
        XCTAssertFalse(presentation.isInProgress)
        XCTAssertFalse(presentation.canRerunFailedTests)
        XCTAssertEqual(presentation.errorCopyText, "The job was cancelled.")
        XCTAssertTrue(presentation.canCopyError)
    }

    func testTimeoutPresentation() {
        let job = makeJob(
            state: .timedOut,
            errorMessage: ProcessRunError.timedOut.localizedDescription
        )
        let presentation = present(job)
        XCTAssertEqual(presentation.stateTitle, "Timed Out")
        XCTAssertFalse(presentation.canStop)
        XCTAssertEqual(presentation.errorCopyText, ProcessRunError.timedOut.localizedDescription)
        XCTAssertFalse(presentation.output.contains("BUILD SUCCEEDED") && presentation.state == .succeeded)
    }

    func testMissingBundlePresentationDisablesOpenResult() {
        let missing = URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).xcresult")
        let job = makeJob(
            state: .succeeded,
            exitCode: 0,
            output: "BUILD SUCCEEDED",
            resultBundleURL: missing,
            summary: .unparsed(.missingBundle, message: "The result bundle was not found at \(missing.path).")
        )
        let presentation = present(job)
        XCTAssertEqual(presentation.state, .succeeded)
        XCTAssertEqual(presentation.diagnosticText, "The result bundle was not found at \(missing.path).")
        XCTAssertFalse(presentation.canOpenResult)
        XCTAssertNil(presentation.resultURL)
        XCTAssertTrue(presentation.canCopyError)
    }

    func testMalformedJSONPresentationKeepsFailure() {
        let bundle = plantBundle("malformed")
        let job = makeJob(
            state: .failed,
            exitCode: 65,
            output: "TEST SUCCEEDED\nAll tests passed",
            resultBundleURL: bundle,
            summary: .unparsed(.schemaMismatch, message: "malformed JSON")
        )
        let presentation = present(job)
        XCTAssertEqual(presentation.state, .failed)
        XCTAssertEqual(presentation.diagnosticText, "malformed JSON")
        XCTAssertTrue(presentation.canOpenResult)
        XCTAssertFalse(presentation.canRerunFailedTests)
        XCTAssertNil(presentation.firstIssueText)
        XCTAssertEqual(presentation.errorCopyText, "malformed JSON")
    }

    func testTwoQueuedBuildsProduceRunningAndQueuedPresentations() {
        let created = Date(timeIntervalSince1970: 1_000)
        let running = makeJob(
            id: UUID(),
            state: .running,
            scheme: "App",
            createdAt: created,
            startedAt: created.addingTimeInterval(1)
        )
        let queued = makeJob(
            id: UUID(),
            state: .queued,
            scheme: "AppTests",
            createdAt: created.addingTimeInterval(2),
            startedAt: nil
        )
        let now = created.addingTimeInterval(13)
        let runningPresentation = IOSBuildJobPresentation.make(
            job: running,
            now: now,
            bundleExists: { [existingBundles] in existingBundles?.contains($0.path) == true }
        )
        let queuedPresentation = IOSBuildJobPresentation.make(
            job: queued,
            now: now,
            bundleExists: { [existingBundles] in existingBundles?.contains($0.path) == true }
        )

        XCTAssertEqual(runningPresentation.state, .running)
        XCTAssertEqual(runningPresentation.stateTitle, "Running")
        XCTAssertTrue(runningPresentation.isInProgress)
        XCTAssertTrue(runningPresentation.canStop)
        XCTAssertEqual(runningPresentation.elapsedText, "0:12")
        XCTAssertTrue(runningPresentation.title.contains("App"))

        XCTAssertEqual(queuedPresentation.state, .queued)
        XCTAssertEqual(queuedPresentation.stateTitle, "Queued")
        XCTAssertTrue(queuedPresentation.isInProgress)
        XCTAssertTrue(queuedPresentation.canStop)
        XCTAssertEqual(queuedPresentation.elapsedText, "0:11")
        XCTAssertTrue(queuedPresentation.title.contains("AppTests"))
    }

    func testElapsedTimeUsesStartAndFinish() {
        let start = Date(timeIntervalSince1970: 50)
        let job = makeJob(
            state: .succeeded,
            createdAt: start.addingTimeInterval(-5),
            startedAt: start,
            finishedAt: start.addingTimeInterval(90)
        )
        XCTAssertEqual(present(job).elapsedText, "1:30")
    }

    // MARK: - Actions

    func testOpenResultUsesFileURLNotShellString() {
        let bundle = plantBundle("result")
        let job = makeJob(state: .failed, resultBundleURL: bundle)
        model.openResult(job: job)
        XCTAssertEqual(opener.opened, [bundle])
        XCTAssertTrue(bundle.isFileURL)
        XCTAssertEqual(bundle.pathExtension, "xcresult")
        XCTAssertFalse(opener.opened.contains { $0.scheme == "http" || $0.scheme == "https" })
    }

    func testOpenSourceFallsBackToResultWhenFileIsMissing() {
        let bundle = plantBundle("fallback")
        let job = makeJob(
            state: .failed,
            errorMessage: "compile failed",
            resultBundleURL: bundle,
            summary: .parsed(outcome: .failed, issues: [
                IOSResultIssue(
                    kind: .buildError,
                    message: "compile failed",
                    fileURL: nil,
                    line: nil,
                    testIdentifier: nil
                )
            ])
        )
        XCTAssertNil(present(job).sourceURL)
        XCTAssertEqual(present(job).resultURL, bundle)
        model.openSource(job: job)
        XCTAssertEqual(opener.opened, [bundle])
    }

    func testCopyErrorUsesIssueMessageNotLogDump() {
        let job = makeJob(
            state: .failed,
            output: String(repeating: "log line\n", count: 40) + "ConsoleUITests/testAll",
            summary: .parsed(outcome: .failed, issues: [
                IOSResultIssue(
                    kind: .testFailure,
                    message: "XCTAssertEqual failed",
                    fileURL: URL(fileURLWithPath: "/tmp/LoginTests.swift"),
                    line: 8,
                    testIdentifier: "AppTests/LoginTests/testLogin"
                )
            ])
        )
        model.copyError(job: job)
        XCTAssertEqual(pasteboard.copied, ["XCTAssertEqual failed"])
        XCTAssertFalse(pasteboard.copied.contains { $0.contains("log line") })
        XCTAssertFalse(pasteboard.copied.contains { $0.contains("ConsoleUITests") })
    }

    func testCopyErrorDoesNotInventIdentifiersFromStdout() {
        let job = makeJob(
            state: .failed,
            output: "ConsoleUITests/AllUITests/testLaunch failed",
            summary: .parsed(outcome: .failed, issues: [
                IOSResultIssue(
                    kind: .buildError,
                    message: "cannot find type",
                    fileURL: URL(fileURLWithPath: "/tmp/A.swift"),
                    line: 1,
                    testIdentifier: nil
                )
            ])
        )
        XCTAssertEqual(present(job).failedTestIdentifiers, [])
        XCTAssertFalse(present(job).canRerunFailedTests)
        model.copyError(job: job)
        XCTAssertEqual(pasteboard.copied, ["cannot find type"])
    }

    func testValidatedFailedIdentifiersIgnoreWildcardsOriginalSelectionAndURLs() {
        let job = makeJob(
            state: .failed,
            kind: .runSelectedTests,
            testSelection: IOSTestSelection(identifiers: ["AppTests", "ConsoleUITests"], testPlan: "FullUI"),
            summary: .parsed(
                outcome: .failed,
                issues: [
                    IOSResultIssue(
                        kind: .testFailure,
                        message: "failed",
                        fileURL: nil,
                        line: nil,
                        testIdentifier: "test://com.apple.xcode/AppTests/LoginTests/testLogin"
                    ),
                    IOSResultIssue(
                        kind: .testFailure,
                        message: "wildcard",
                        fileURL: nil,
                        line: nil,
                        testIdentifier: "ConsoleUITests*"
                    ),
                    IOSResultIssue(
                        kind: .testFailure,
                        message: "target only",
                        fileURL: nil,
                        line: nil,
                        testIdentifier: "ConsoleUITests"
                    ),
                    IOSResultIssue(
                        kind: .buildError,
                        message: "also a compile issue",
                        fileURL: nil,
                        line: nil,
                        testIdentifier: "AppTests/LoginTests/testLogout"
                    )
                ]
            )
        )
        XCTAssertEqual(
            IOSFailedTestIdentifier.from(job: job),
            ["AppTests/LoginTests/testLogin"]
        )
        XCTAssertFalse(IOSFailedTestIdentifier.from(job: job).contains("ConsoleUITests"))
        XCTAssertFalse(IOSFailedTestIdentifier.from(job: job).contains("AppTests/LoginTests/testLogout"))
    }

    func testRerunFailedTestsSubmitsOnlyValidatedIdentifiers() async throws {
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
        runner.result = ProcessResult(exitCode: 65, standardOutput: "ConsoleUITests failed", standardError: "")

        var profile = sampleProfile(testPlan: "FullSuite")
        let firstID = try coordinator.submitSelectedTests(
            profile: profile,
            identifiers: [
                "AppTests/LoginTests/testLogin",
                "AppTests/LoginTests/testLogout",
                "ConsoleUITests/Smoke"
            ]
        )
        let first = try await waitForJob(firstID)
        profile.scheme = "Mutated"
        profile.testPlan = "ShouldNotUse"

        model.rerunFailedTests(coordinator: coordinator, job: first)
        let rerunID = try XCTUnwrap(model.selectedJobID)
        XCTAssertNotEqual(rerunID, firstID)
        let rerun = try await waitForJob(rerunID)

        XCTAssertEqual(rerun.kind, .runSelectedTests)
        XCTAssertEqual(rerun.testSelection?.identifiers, ["AppTests/LoginTests/testLogin"])
        XCTAssertNil(rerun.testSelection?.testPlan)
        XCTAssertEqual(rerun.profile.scheme, "App")
        XCTAssertEqual(rerun.profile.testPlan, "FullSuite")

        let args = try XCTUnwrap(runner.invocations.last).arguments
        XCTAssertEqual(args.filter { $0.hasPrefix("-only-testing:") }, [
            "-only-testing:AppTests/LoginTests/testLogin"
        ])
        XCTAssertFalse(args.contains("-testPlan"))
        XCTAssertFalse(args.contains { $0.contains("testLogout") })
        XCTAssertFalse(args.contains { $0.contains("UITest") })
        XCTAssertFalse(args.contains { $0.contains("FullSuite") })
        XCTAssertFalse(args.contains { $0.contains("Mutated") })
        XCTAssertEqual(args.first, "test")
    }

    func testRerunWithoutFailedIdentifiersDoesNotEnqueue() {
        let job = makeJob(state: .failed, summary: .parsed(outcome: .failed, issues: [
            IOSResultIssue(kind: .buildError, message: "boom", fileURL: nil, line: nil, testIdentifier: nil)
        ]))
        model.rerunFailedTests(coordinator: coordinator, job: job)
        XCTAssertTrue(coordinator.jobs.isEmpty)
        XCTAssertEqual(model.actionMessage, "No failed tests to rerun.")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testStopCancelsSelectedRunningJob() async throws {
        runner.hold = true
        let id = try coordinator.submitBuild(profile: sampleProfile())
        try await waitUntil { self.coordinator.job(id: id)?.state == .running }
        model.selectedJobID = id
        model.stop(coordinator: coordinator, jobs: coordinator.jobs)
        let job = try await waitForJob(id)
        XCTAssertEqual(job.state, .cancelled)
    }

    func testCoordinatorQueuedPairMatchesPresentation() async throws {
        runner.hold = true
        let first = try coordinator.submitBuild(profile: sampleProfile(scheme: "App"))
        let second = try coordinator.submitBuild(profile: sampleProfile(scheme: "AppTests"))
        try await waitUntil { self.coordinator.job(id: first)?.state == .running }

        let running = try XCTUnwrap(coordinator.job(id: first))
        let queued = try XCTUnwrap(coordinator.job(id: second))
        XCTAssertEqual(present(running).state, .running)
        XCTAssertEqual(present(queued).state, .queued)
        XCTAssertTrue(present(running).canStop)
        XCTAssertTrue(present(queued).canStop)
        XCTAssertNotEqual(running.resultBundleURL, queued.resultBundleURL)

        model.selectedJobID = second
        model.stop(coordinator: coordinator, jobs: coordinator.jobs)
        XCTAssertEqual(coordinator.job(id: second)?.state, .cancelled)
        XCTAssertEqual(present(try XCTUnwrap(coordinator.job(id: second))).state, .cancelled)

        runner.releaseOne()
        _ = try await waitForJob(first)
        XCTAssertEqual(present(try XCTUnwrap(coordinator.job(id: first))).state, .succeeded)
    }

    func testSelectLatestIfNeeded() {
        let first = makeJob(id: UUID(), state: .succeeded)
        let second = makeJob(id: UUID(), state: .queued)
        model.selectLatestIfNeeded(from: [first, second])
        XCTAssertEqual(model.selectedJobID, second.id)
        model.selectLatestIfNeeded(from: [first, second])
        XCTAssertEqual(model.selectedJobID, second.id)
    }

    // MARK: - Helpers

    private func makeModel() -> IOSBuildJobPanelModel {
        IOSBuildJobPanelModel(
            opener: opener,
            pasteboard: pasteboard,
            bundleExists: { [weak self] url in
                self?.existingBundles.contains(url.path) == true
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func present(_ job: IOSBuildJob) -> IOSBuildJobPresentation {
        model.presentation(for: job)
    }

    private func plantBundle(_ name: String) -> URL {
        let url = tmpRoot.appendingPathComponent("\(name).xcresult")
        existingBundles.insert(url.path)
        return url
    }

    private func makeJob(
        id: UUID = UUID(),
        state: IOSBuildJobState,
        kind: IOSBuildJobKind = .build,
        scheme: String = "App",
        exitCode: Int32? = nil,
        output: String = "",
        errorMessage: String? = nil,
        resultBundleURL: URL? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        startedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        finishedAt: Date? = nil,
        testSelection: IOSTestSelection? = nil,
        summary: IOSResultSummary? = nil
    ) -> IOSBuildJob {
        var job = IOSBuildJob.queued(
            id: id,
            kind: kind,
            profile: sampleProfile(scheme: scheme),
            testSelection: testSelection,
            resultBundleURL: resultBundleURL ?? tmpRoot.appendingPathComponent("\(id.uuidString).xcresult"),
            createdAt: createdAt
        )
        job.state = state
        job.startedAt = startedAt
        job.finishedAt = finishedAt ?? (state.isTerminal ? createdAt.addingTimeInterval(3) : nil)
        job.exitCode = exitCode
        job.standardOutput = output
        job.errorMessage = errorMessage
        job.resultSummary = summary
        return job
    }

    private func sampleProfile(
        scheme: String = "App",
        testPlan: String? = nil
    ) -> IOSProjectProfile {
        IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: "/tmp/App.xcodeproj",
            scheme: scheme,
            configuration: "Debug",
            testPlan: testPlan,
            simulatorUDID: "SIM-1"
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

private final class RecordingIOSWorkspaceOpener: IOSWorkspaceOpening, @unchecked Sendable {
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

private final class RecordingIOSPasteboard: IOSPasteboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var copiedStorage: [String] = []
    var copied: [String] {
        lock.lock()
        defer { lock.unlock() }
        return copiedStorage
    }

    func write(_ string: String) {
        lock.lock()
        copiedStorage.append(string)
        lock.unlock()
    }
}

private final class FakeJobProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executablePath: String
        var arguments: [String]
        var workingDirectory: String?
        var deadline: Date?
    }

    private let lock = NSLock()
    private var invocationsStorage: [Invocation] = []
    private var releasedCount = 0
    private var stopHolds = false

    var hold = false
    var result = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    var error: Error?

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
        if let error { throw error }
        return result
    }
}

private final class FakeJobResultParser: IOSResultParsing, @unchecked Sendable {
    private let lock = NSLock()
    var summary = IOSResultSummary.parsed(outcome: .succeeded, issues: [])

    func parseBundle(at url: URL, jobKind: IOSBuildJobKind) async -> IOSResultSummary {
        lock.lock()
        let summary = self.summary
        lock.unlock()
        return summary
    }
}
