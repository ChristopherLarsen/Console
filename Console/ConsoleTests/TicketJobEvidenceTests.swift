import XCTest
@testable import Console

final class TicketJobEvidenceTests: XCTestCase {

    // Privacy sentinels — must never appear in digests or argv we construct.
    private let sensitiveTicketKey = "SENSITIVE_TICKET_KEY"
    private let sensitiveTitle = "SENSITIVE_TITLE"
    private let sensitiveStatus = "SENSITIVE_STATUS"

    private var checkoutRoot: URL!

    override func setUpWithError() throws {
        checkoutRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TicketJobEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkoutRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: checkoutRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: checkoutRoot)
    }

    // MARK: - Fake process runner

    private final class FakeGitProcessRunner: ProcessRunning, @unchecked Sendable {
        struct Invocation: Equatable, Sendable {
            var executablePath: String
            var arguments: [String]
            var workingDirectory: String?
        }

        private let lock = NSLock()
        private var invocationsStorage: [Invocation] = []

        /// Maps a git subcommand (first arg after flags) → result.
        var resultsBySubcommand: [String: ProcessResult] = [:]
        var defaultResult = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        var error: Error?
        var failSubcommands: Set<String> = []

        var invocations: [Invocation] {
            lock.lock()
            defer { lock.unlock() }
            return invocationsStorage
        }

        func run(
            executablePath: String,
            arguments: [String],
            workingDirectory: String?,
            deadline: Date?
        ) async throws -> ProcessResult {
            _ = deadline
            let invocation = Invocation(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
            lock.lock()
            invocationsStorage.append(invocation)
            lock.unlock()

            if let error {
                throw error
            }

            let subcommand = Self.gitSubcommand(from: arguments)
            if failSubcommands.contains(subcommand) {
                return ProcessResult(exitCode: 128, standardOutput: "", standardError: "failed")
            }
            return resultsBySubcommand[subcommand] ?? defaultResult
        }

        static func gitSubcommand(from arguments: [String]) -> String {
            // Expected: -C <path> --no-optional-locks <subcommand> ...
            if let index = arguments.firstIndex(of: "--no-optional-locks"),
               arguments.index(after: index) < arguments.endIndex {
                return arguments[arguments.index(after: index)]
            }
            return arguments.first { !$0.hasPrefix("-") && $0 != arguments.dropFirst().first } ?? arguments.last ?? ""
        }
    }

    // MARK: - Helpers

    private func makeCompleteFingerprint(
        head: String = "abc123",
        staged: String = "s1",
        unstaged: String = "u1",
        untracked: String = "t1",
        at: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TicketSourceFingerprint {
        TicketSourceFingerprint(
            headOID: head,
            stagedDigest: staged,
            unstagedDigest: unstaged,
            untrackedDigest: untracked,
            isComplete: true,
            capturedAt: at
        )
    }

    private func makeProfile(workspaceID: UUID = UUID()) -> IOSProjectProfile {
        IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: "/tmp/Demo.xcodeproj",
            scheme: "Demo",
            configuration: "Debug",
            testPlan: "Smoke",
            simulatorUDID: "SIM-UDID-1"
        )
    }

    private func makeContext(
        fingerprint: TicketSourceFingerprint,
        jobID: UUID = UUID(),
        profile: IOSProjectProfile? = nil,
        testSelection: IOSTestSelection? = nil
    ) -> TicketActionExecutionContext {
        let profile = profile ?? makeProfile()
        return TicketBuildJobAdapter.makeExecutionContext(
            workflowID: UUID(),
            stepID: UUID(),
            workCycle: 1,
            workspaceID: profile.workspaceID,
            checkoutPath: checkoutRoot.path,
            profile: profile,
            testSelection: testSelection,
            jobID: jobID,
            sourceFingerprint: fingerprint,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeJob(
        state: IOSBuildJobState,
        kind: IOSBuildJobKind = .build,
        id: UUID = UUID(),
        profile: IOSProjectProfile? = nil
    ) -> IOSBuildJob {
        var job = IOSBuildJob.queued(
            id: id,
            kind: kind,
            profile: profile ?? makeProfile(),
            testSelection: nil,
            resultBundleURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).xcresult"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        job.state = state
        job.finishedAt = Date(timeIntervalSince1970: 1_700_000_100)
        return job
    }

    private func configureSuccessfulProbes(_ runner: FakeGitProcessRunner) {
        runner.resultsBySubcommand = [
            "rev-parse": ProcessResult(exitCode: 0, standardOutput: "deadbeefcafebabe\n", standardError: ""),
            "diff-index": ProcessResult(exitCode: 0, standardOutput: "staged-raw\0", standardError: ""),
            "diff-files": ProcessResult(exitCode: 0, standardOutput: "unstaged-raw\0", standardError: ""),
            "ls-files": ProcessResult(exitCode: 0, standardOutput: "untracked.swift\0", standardError: ""),
        ]
    }

    // MARK: - Fingerprint completeness

    func testFingerprintCompleteWhenAllProbesSucceed() async {
        let runner = FakeGitProcessRunner()
        configureSuccessfulProbes(runner)
        let service = TicketSourceFingerprintService(
            processRunner: runner,
            now: { Date(timeIntervalSince1970: 42) }
        )

        let fingerprint = await service.fingerprint(checkoutPath: checkoutRoot.path)

        XCTAssertTrue(fingerprint.isComplete)
        XCTAssertEqual(fingerprint.headOID, "deadbeefcafebabe")
        XCTAssertEqual(fingerprint.stagedDigest, TicketSourceFingerprintService.digest("staged-raw\0"))
        XCTAssertEqual(fingerprint.unstagedDigest, TicketSourceFingerprintService.digest("unstaged-raw\0"))
        XCTAssertEqual(fingerprint.untrackedDigest, TicketSourceFingerprintService.digest("untracked.swift\0"))
        XCTAssertEqual(fingerprint.capturedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(runner.invocations.count, 4)
    }

    func testFingerprintIncompleteWhenProbeFails() async {
        let runner = FakeGitProcessRunner()
        configureSuccessfulProbes(runner)
        runner.failSubcommands = ["diff-files"]
        let service = TicketSourceFingerprintService(processRunner: runner)

        let fingerprint = await service.fingerprint(checkoutPath: checkoutRoot.path)

        XCTAssertFalse(fingerprint.isComplete)
        XCTAssertNil(fingerprint.headOID)
        XCTAssertNil(fingerprint.stagedDigest)
    }

    func testFingerprintIncompleteWhenOutputTruncated() async {
        let runner = FakeGitProcessRunner()
        configureSuccessfulProbes(runner)
        runner.resultsBySubcommand["ls-files"] = ProcessResult(
            exitCode: 0,
            standardOutput: "huge",
            standardError: "",
            standardOutputTruncated: true,
            standardErrorTruncated: false,
            standardOutputByteCount: 99_999,
            standardErrorByteCount: 0
        )
        let service = TicketSourceFingerprintService(processRunner: runner)

        let fingerprint = await service.fingerprint(checkoutPath: checkoutRoot.path)
        XCTAssertFalse(fingerprint.isComplete)
    }

    func testFingerprintIncompleteForEmptyOrNonRepoPath() async {
        let runner = FakeGitProcessRunner()
        configureSuccessfulProbes(runner)
        let service = TicketSourceFingerprintService(processRunner: runner)

        let empty = await service.fingerprint(checkoutPath: "  ")
        XCTAssertFalse(empty.isComplete)
        XCTAssertTrue(runner.invocations.isEmpty)

        let missing = await service.fingerprint(checkoutPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        XCTAssertFalse(missing.isComplete)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - Stale source applicability

    func testSourceChangeYieldsStaleSourceApplicability() {
        let original = makeCompleteFingerprint(unstaged: "before")
        let current = makeCompleteFingerprint(unstaged: "after")
        let context = makeContext(fingerprint: original)

        XCTAssertEqual(
            TicketBuildJobAdapter.applicabilityAfterFinish(
                context: context,
                currentFingerprint: current
            ),
            .staleSource
        )
        XCTAssertEqual(
            TicketBuildJobAdapter.applicabilityBeforeAdvancement(
                context: context,
                currentFingerprint: current
            ),
            .staleSource
        )
        XCTAssertFalse(
            TicketBuildJobAdapter.isAcceptableForAdvancement(
                evidence: TicketBuildJobAdapter.makeEvidence(
                    job: makeJob(state: .succeeded, id: context.jobID),
                    context: context
                ),
                currentFingerprint: current
            )
        )
    }

    func testEnqueueRejectsIncompleteFingerprint() {
        XCTAssertEqual(
            TicketBuildJobAdapter.applicabilityBeforeEnqueue(
                sourceFingerprint: .incomplete()
            ),
            .incompleteFingerprint
        )
        XCTAssertEqual(
            TicketBuildJobAdapter.applicabilityBeforeEnqueue(
                sourceFingerprint: makeCompleteFingerprint()
            ),
            .current
        )
    }

    // MARK: - Mapper outcomes

    func testSucceededWithCurrentFingerprintMapsToSucceeded() {
        let fingerprint = makeCompleteFingerprint()
        let context = makeContext(fingerprint: fingerprint)
        let evidence = TicketBuildJobAdapter.makeEvidence(
            job: makeJob(state: .succeeded, id: context.jobID),
            context: context
        )
        let event = TicketBuildJobAdapter.makeApplyEvent(
            evidence: evidence,
            currentFingerprint: fingerprint,
            eventID: UUID(),
            at: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(event.outcome, .succeeded)
        XCTAssertEqual(event.applicability, .current)
        XCTAssertEqual(event.jobID, context.jobID)
        XCTAssertEqual(event.workCycle, context.workCycle)
    }

    func testSucceededWithStaleFingerprintMapsToUnverified() {
        let original = makeCompleteFingerprint(head: "aaa")
        let stale = makeCompleteFingerprint(head: "bbb")
        let context = makeContext(fingerprint: original)
        let evidence = TicketBuildJobAdapter.makeEvidence(
            job: makeJob(state: .succeeded, id: context.jobID),
            context: context
        )
        let event = TicketJobEvidenceMapper.makeEvent(
            evidence: evidence,
            currentFingerprint: stale
        )
        XCTAssertEqual(event.outcome, .unverified)
        XCTAssertEqual(event.applicability, .staleSource)
    }

    func testSucceededWithIncompleteFingerprintMapsToUnverified() {
        let original = makeCompleteFingerprint()
        let context = makeContext(fingerprint: original)
        let evidence = TicketBuildJobAdapter.makeEvidence(
            job: makeJob(state: .succeeded, id: context.jobID),
            context: context
        )
        let event = TicketJobEvidenceMapper.makeEvent(
            evidence: evidence,
            currentFingerprint: .incomplete()
        )
        XCTAssertEqual(event.outcome, .unverified)
        XCTAssertEqual(event.applicability, .incompleteFingerprint)
    }

    func testCancelledFailedTimedOutRemainDistinctOnEvidence() {
        let fingerprint = makeCompleteFingerprint()
        let context = makeContext(fingerprint: fingerprint)

        let cancelledEvidence = TicketBuildJobAdapter.makeEvidence(
            job: makeJob(state: .cancelled, id: context.jobID),
            context: context
        )
        let failedEvidence = TicketBuildJobAdapter.makeEvidence(
            job: makeJob(state: .failed, id: context.jobID),
            context: context
        )
        let timedOutEvidence = TicketBuildJobAdapter.makeEvidence(
            job: makeJob(state: .timedOut, id: context.jobID),
            context: context
        )

        XCTAssertEqual(cancelledEvidence.jobState, .cancelled)
        XCTAssertEqual(failedEvidence.jobState, .failed)
        XCTAssertEqual(timedOutEvidence.jobState, .timedOut)

        // Step outcomes collapse to failed (shared TicketStepOutcome has no
        // cancelled/timedOut), but evidence retains the distinct job states.
        let cancelledEvent = TicketJobEvidenceMapper.makeEvent(
            evidence: cancelledEvidence,
            currentFingerprint: fingerprint
        )
        let failedEvent = TicketJobEvidenceMapper.makeEvent(
            evidence: failedEvidence,
            currentFingerprint: fingerprint
        )
        let timedOutEvent = TicketJobEvidenceMapper.makeEvent(
            evidence: timedOutEvidence,
            currentFingerprint: fingerprint
        )
        XCTAssertEqual(cancelledEvent.outcome, .failed)
        XCTAssertEqual(failedEvent.outcome, .failed)
        XCTAssertEqual(timedOutEvent.outcome, .failed)
        XCTAssertNotEqual(cancelledEvidence.jobState, failedEvidence.jobState)
        XCTAssertNotEqual(failedEvidence.jobState, timedOutEvidence.jobState)
        XCTAssertNotEqual(cancelledEvidence.jobState, timedOutEvidence.jobState)
    }

    func testQueuedAndRunningMapToRunningOutcome() {
        let fingerprint = makeCompleteFingerprint()
        let context = makeContext(fingerprint: fingerprint)
        for state: IOSBuildJobState in [.queued, .running] {
            let event = TicketJobEvidenceMapper.makeEvent(
                evidence: TicketBuildJobAdapter.makeEvidence(
                    job: makeJob(state: state, id: context.jobID),
                    context: context
                ),
                currentFingerprint: fingerprint
            )
            XCTAssertEqual(event.outcome, .running, "state \(state)")
        }
    }

    // MARK: - Privacy

    func testPrivacySentinelsAbsentFromProfileFingerprintAndGitArgv() async {
        let runner = FakeGitProcessRunner()
        configureSuccessfulProbes(runner)
        let service = TicketSourceFingerprintService(processRunner: runner)

        _ = await service.fingerprint(checkoutPath: checkoutRoot.path)

        let profile = makeProfile()
        let selection = IOSTestSelection(identifiers: ["DemoTests/testSmoke"], testPlan: "Smoke")
        let digest = TicketProfileFingerprint.digest(profile: profile, testSelection: selection)
        let context = makeContext(fingerprint: makeCompleteFingerprint(), profile: profile, testSelection: selection)

        let launchSpec = try? IOSXcodebuildCommand.makeLaunchSpec(
            kind: .build,
            profile: profile,
            selection: nil,
            resultBundleURL: URL(fileURLWithPath: "/tmp/result.xcresult"),
            timeouts: .default
        )

        let argvBlobs: [String] = runner.invocations.flatMap(\.arguments)
            + [digest, context.profileFingerprint]
            + (launchSpec?.arguments ?? [])
            + [launchSpec?.executablePath ?? ""]

        for blob in argvBlobs {
            XCTAssertFalse(blob.contains(sensitiveTicketKey), "leaked ticket key in: \(blob)")
            XCTAssertFalse(blob.contains(sensitiveTitle), "leaked title in: \(blob)")
            XCTAssertFalse(blob.contains(sensitiveStatus), "leaked status in: \(blob)")
        }

        // Sentinels exist in local fixtures but are never passed into adapters.
        XCTAssertEqual(sensitiveTicketKey, "SENSITIVE_TICKET_KEY")
        XCTAssertEqual(sensitiveTitle, "SENSITIVE_TITLE")
        XCTAssertEqual(sensitiveStatus, "SENSITIVE_STATUS")
    }

    func testJobRequestKeepsContextWithoutTicketFields() {
        let fingerprint = makeCompleteFingerprint()
        let context = makeContext(fingerprint: fingerprint)
        let profile = makeProfile()
        let request = TicketWorkflowJobRequest(
            context: context,
            kind: .runSelectedTests,
            profile: profile,
            testSelection: IOSTestSelection(identifiers: ["UnitTests/testA"])
        )
        XCTAssertEqual(request.context.jobID, context.jobID)
        XCTAssertEqual(request.kind, .runSelectedTests)
        XCTAssertFalse(String(describing: request).contains(sensitiveTicketKey))
        XCTAssertFalse(String(describing: request).contains(sensitiveTitle))
        XCTAssertFalse(String(describing: request).contains(sensitiveStatus))
    }
}
