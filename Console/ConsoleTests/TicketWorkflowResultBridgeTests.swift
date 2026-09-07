import XCTest
@testable import Console

final class TicketWorkflowResultBridgeTests: XCTestCase {

    private let sensitiveTicketKey = "SENSITIVE_TICKET_KEY"
    private let sensitiveTitle = "SENSITIVE_TITLE"
    private let sensitiveStatus = "SENSITIVE_STATUS"

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 10
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TicketWorkflowResultBridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - Fakes

    private final class RecordingOpener: IOSWorkspaceOpening, @unchecked Sendable {
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

    private final class RecordingPasteboard: IOSPasteboardWriting, @unchecked Sendable {
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

    // MARK: - Fixtures

    private func plantBundle(_ name: String = "job") -> URL {
        let url = tmpRoot.appendingPathComponent("\(name).xcresult", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func parsedSuccess(
        issues: [IOSResultIssue] = []
    ) -> IOSResultSummary {
        .parsed(outcome: .succeeded, issues: issues, errorCount: 0, failedTestCount: 0)
    }

    private func parsedFailure(
        issues: [IOSResultIssue],
        errorCount: Int? = nil,
        failedTestCount: Int? = nil
    ) -> IOSResultSummary {
        .parsed(
            outcome: .failed,
            issues: issues,
            errorCount: errorCount,
            failedTestCount: failedTestCount
        )
    }

    private func makeFingerprint(
        head: String = "abc123",
        staged: String = "s1",
        unstaged: String = "u1",
        untracked: String = "t1"
    ) -> TicketSourceFingerprint {
        TicketSourceFingerprint(
            headOID: head,
            stagedDigest: staged,
            unstagedDigest: unstaged,
            untrackedDigest: untracked,
            isComplete: true,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeEvidence(
        jobState: IOSBuildJobState,
        fingerprint: TicketSourceFingerprint,
        bundleURL: URL? = nil
    ) -> TicketJobEvidence {
        let profile = IOSProjectProfile(
            workspaceID: UUID(),
            projectPath: "Demo.xcodeproj",
            scheme: "Demo",
            configuration: "Debug",
            testPlan: nil,
            simulatorUDID: "SIM-1"
        )
        let context = TicketBuildJobAdapter.makeExecutionContext(
            workflowID: UUID(),
            stepID: UUID(),
            workCycle: 1,
            workspaceID: profile.workspaceID,
            checkoutPath: tmpRoot.path,
            profile: profile,
            testSelection: nil,
            jobID: UUID(),
            sourceFingerprint: fingerprint,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return TicketJobEvidence(
            context: context,
            jobState: jobState,
            kind: .build,
            resultBundleURL: bundleURL ?? tmpRoot.appendingPathComponent("x.xcresult"),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    // MARK: - Successful verification

    func testParsedSuccessIsSuccessfulVerification() {
        let bundle = plantBundle()
        let presentation = TicketWorkflowResultBridge.makePresentation(
            summary: parsedSuccess(),
            resultBundleURL: bundle,
            jobState: .succeeded,
            bundleExists: { _ in true }
        )
        XCTAssertEqual(presentation.availability, .parsed)
        XCTAssertEqual(presentation.recordOutcome, .succeeded)
        XCTAssertTrue(presentation.isSuccessfulVerification)
        XCTAssertEqual(presentation.verificationOutcome, .succeeded)
        XCTAssertEqual(presentation.resultBundleURL, bundle)
        XCTAssertTrue(presentation.canOpenResult)
    }

    // MARK: - Unreadable results never succeed

    func testMissingCorruptIncompleteSchemaToolAndUnavailableNeverSucceed() {
        let cases: [(IOSResultSummary?, TicketWorkflowResultAvailability)] = [
            (.unparsed(.missingBundle, message: "missing"), .missingBundle),
            (.unparsed(.incompleteBundle, message: "truncated"), .incompleteBundle),
            (.unparsed(.corruptBundle, message: "corrupt"), .corruptBundle),
            (.unparsed(.schemaMismatch, message: "schema"), .schemaMismatch),
            (.unparsed(.toolFailed, message: "tool"), .toolFailed),
            (nil, .unavailable),
        ]
        for (summary, expectedAvailability) in cases {
            let presentation = TicketWorkflowResultBridge.makePresentation(
                summary: summary,
                resultBundleURL: plantBundle(),
                jobState: .succeeded,
                bundleExists: { _ in true }
            )
            XCTAssertEqual(presentation.availability, expectedAvailability, "\(expectedAvailability)")
            XCTAssertTrue(
                presentation.availability.blocksSuccessfulVerification,
                "\(expectedAvailability)"
            )
            XCTAssertFalse(presentation.isSuccessfulVerification, "\(expectedAvailability)")
            XCTAssertEqual(presentation.verificationOutcome, .unverified, "\(expectedAvailability)")
            XCTAssertEqual(
                TicketWorkflowResultBridge.verificationOutcome(jobState: .succeeded, summary: summary),
                .unverified,
                "\(expectedAvailability)"
            )
        }
    }

    func testParsedFailureMapsToFailedNotSucceeded() {
        let issue = IOSResultIssue(
            kind: .buildError,
            message: "cannot find type Demo",
            fileURL: URL(fileURLWithPath: "/tmp/Demo.swift"),
            line: 12,
            testIdentifier: nil
        )
        let summary = parsedFailure(issues: [issue], errorCount: 1)
        let presentation = TicketWorkflowResultBridge.makePresentation(
            summary: summary,
            resultBundleURL: plantBundle(),
            jobState: .succeeded,
            bundleExists: { _ in true }
        )
        XCTAssertFalse(presentation.isSuccessfulVerification)
        XCTAssertEqual(presentation.verificationOutcome, .failed)
        XCTAssertEqual(presentation.errorCount, 1)
        XCTAssertEqual(presentation.issues.count, 1)
        XCTAssertEqual(presentation.sourceURL?.path, "/tmp/Demo.swift")
        XCTAssertTrue(presentation.canOpenSource)
        XCTAssertEqual(presentation.errorCopyText, "cannot find type Demo")
    }

    func testParsedUnknownOutcomeIsUnverified() {
        let summary = IOSResultSummary.parsed(outcome: .unknown, issues: [])
        XCTAssertEqual(
            TicketWorkflowResultBridge.verificationOutcome(jobState: .succeeded, summary: summary),
            .unverified
        )
    }

    func testFailedCancelledTimedOutAlwaysFailed() {
        let successSummary = parsedSuccess()
        for state: IOSBuildJobState in [.failed, .cancelled, .timedOut] {
            XCTAssertEqual(
                TicketWorkflowResultBridge.verificationOutcome(jobState: state, summary: successSummary),
                .failed,
                "\(state)"
            )
            XCTAssertEqual(
                TicketWorkflowResultBridge.verificationOutcome(jobState: state, summary: nil),
                .failed,
                "\(state) nil"
            )
        }
    }

    func testQueuedAndRunningMapToRunning() {
        for state: IOSBuildJobState in [.queued, .running] {
            XCTAssertEqual(
                TicketWorkflowResultBridge.verificationOutcome(jobState: state, summary: nil),
                .running
            )
        }
    }

    // MARK: - Refine Package C outcomes

    func testRefineDemotesPackageCSuccessWhenBundleUnreadable() {
        let summary = IOSResultSummary.unparsed(.corruptBundle, message: "corrupt")
        XCTAssertEqual(
            TicketWorkflowResultBridge.refineEvidenceOutcome(
                .succeeded,
                jobState: .succeeded,
                summary: summary
            ),
            .unverified
        )
        XCTAssertEqual(
            TicketWorkflowResultBridge.refineEvidenceOutcome(
                .succeeded,
                jobState: .succeeded,
                summary: nil
            ),
            .unverified
        )
    }

    func testRefineKeepsFailedAndPreservesHonestSuccess() {
        XCTAssertEqual(
            TicketWorkflowResultBridge.refineEvidenceOutcome(
                .failed,
                jobState: .failed,
                summary: parsedSuccess()
            ),
            .failed
        )
        XCTAssertEqual(
            TicketWorkflowResultBridge.refineEvidenceOutcome(
                .succeeded,
                jobState: .succeeded,
                summary: parsedSuccess()
            ),
            .succeeded
        )
        XCTAssertEqual(
            TicketWorkflowResultBridge.refineEvidenceOutcome(
                .unverified,
                jobState: .succeeded,
                summary: parsedSuccess()
            ),
            .unverified
        )
    }

    func testMakeApplyEventDemotesSuccessForTruncatedResult() {
        let fingerprint = makeFingerprint()
        let evidence = makeEvidence(jobState: .succeeded, fingerprint: fingerprint)
        let truncated = IOSResultSummary.unparsed(
            .incompleteBundle,
            message: "xcresulttool output was truncated before it could be parsed."
        )
        let event = TicketWorkflowResultBridge.makeApplyEvent(
            evidence: evidence,
            resultSummary: truncated,
            currentFingerprint: fingerprint
        )
        XCTAssertEqual(event.outcome, .unverified)
        XCTAssertEqual(event.applicability, .current)
        XCTAssertNotEqual(event.outcome, .succeeded)
    }

    func testIsAcceptableForAdvancementRequiresReadableSuccess() {
        let fingerprint = makeFingerprint()
        let evidence = makeEvidence(jobState: .succeeded, fingerprint: fingerprint)
        XCTAssertTrue(
            TicketWorkflowResultBridge.isAcceptableForAdvancement(
                evidence: evidence,
                resultSummary: parsedSuccess(),
                currentFingerprint: fingerprint
            )
        )
        XCTAssertFalse(
            TicketWorkflowResultBridge.isAcceptableForAdvancement(
                evidence: evidence,
                resultSummary: .unparsed(.missingBundle, message: "gone"),
                currentFingerprint: fingerprint
            )
        )
        XCTAssertFalse(
            TicketWorkflowResultBridge.isAcceptableForAdvancement(
                evidence: evidence,
                resultSummary: nil,
                currentFingerprint: fingerprint
            )
        )
    }

    // MARK: - Action helpers

    func testOpenResultAndSourceAndCopyErrorHelpers() {
        let bundle = plantBundle("actions")
        let source = URL(fileURLWithPath: "/tmp/FixtureTests.swift")
        let summary = parsedFailure(issues: [
            IOSResultIssue(
                kind: .testFailure,
                message: "XCTAssertEqual failed: fake",
                fileURL: source,
                line: 9,
                testIdentifier: "DemoTests/LoginTests/testLogin"
            )
        ], failedTestCount: 1)
        let presentation = TicketWorkflowResultBridge.makePresentation(
            summary: summary,
            resultBundleURL: bundle,
            jobState: .failed,
            bundleExists: { $0 == bundle }
        )

        XCTAssertEqual(TicketWorkflowResultBridge.resultURLToOpen(from: presentation), bundle)
        XCTAssertEqual(TicketWorkflowResultBridge.sourceURLToOpen(from: presentation), source)
        XCTAssertEqual(
            TicketWorkflowResultBridge.errorTextToCopy(from: presentation),
            "XCTAssertEqual failed: fake"
        )

        let opener = RecordingOpener()
        let pasteboard = RecordingPasteboard()
        TicketWorkflowResultBridge.performOpenResult(presentation: presentation, opener: opener)
        TicketWorkflowResultBridge.performOpenSource(presentation: presentation, opener: opener)
        TicketWorkflowResultBridge.performCopyError(presentation: presentation, pasteboard: pasteboard)
        XCTAssertEqual(opener.opened, [bundle, source])
        XCTAssertEqual(pasteboard.copied, ["XCTAssertEqual failed: fake"])
    }

    func testOpenSourceFallsBackToResultBundle() {
        let bundle = plantBundle("fallback")
        let presentation = TicketWorkflowResultBridge.makePresentation(
            summary: parsedFailure(issues: [
                IOSResultIssue(
                    kind: .buildError,
                    message: "boom",
                    fileURL: nil,
                    line: nil,
                    testIdentifier: nil
                )
            ]),
            resultBundleURL: bundle,
            jobState: .failed,
            bundleExists: { _ in true }
        )
        XCTAssertNil(presentation.sourceURL)
        XCTAssertEqual(TicketWorkflowResultBridge.sourceURLToOpen(from: presentation), bundle)
    }

    func testRerunFailedTestsSelectionUsesValidatedIdentifiersOnly() {
        let summary = parsedFailure(issues: [
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
                message: "compile",
                fileURL: nil,
                line: nil,
                testIdentifier: "AppTests/LoginTests/testLogout"
            ),
        ], failedTestCount: 2)

        XCTAssertEqual(
            TicketWorkflowResultBridge.failedTestIdentifiers(from: summary),
            ["AppTests/LoginTests/testLogin"]
        )
        let selection = TicketWorkflowResultBridge.rerunFailedTestSelection(from: summary)
        XCTAssertEqual(selection?.identifiers, ["AppTests/LoginTests/testLogin"])
        XCTAssertNil(selection?.testPlan)

        let buildOnly = parsedFailure(issues: [
            IOSResultIssue(kind: .buildError, message: "x", fileURL: nil, line: nil, testIdentifier: nil)
        ])
        XCTAssertNil(TicketWorkflowResultBridge.rerunFailedTestSelection(from: buildOnly))
    }

    func testMissingBundleDisablesOpenResult() {
        let missing = tmpRoot.appendingPathComponent("absent.xcresult")
        let presentation = TicketWorkflowResultBridge.makePresentation(
            summary: .unparsed(.missingBundle, message: "missing"),
            resultBundleURL: missing,
            jobState: .succeeded,
            bundleExists: { _ in false }
        )
        XCTAssertFalse(presentation.canOpenResult)
        XCTAssertNil(TicketWorkflowResultBridge.resultURLToOpen(from: presentation))
        XCTAssertNil(presentation.resultBundleURL)
    }

    // MARK: - Privacy

    func testPresentationOmitsTicketAndMRFieldsAndSentinels() {
        let summary = parsedFailure(issues: [
            IOSResultIssue(
                kind: .testFailure,
                message: "assertion failed in fixture",
                fileURL: URL(fileURLWithPath: "/tmp/Fixture.swift"),
                line: 3,
                testIdentifier: "FixtureTests/ExampleTests/testExample"
            )
        ], failedTestCount: 1)
        let presentation = TicketWorkflowResultBridge.makePresentation(
            summary: summary,
            resultBundleURL: plantBundle(),
            jobState: .failed,
            jobErrorMessage: "process failed",
            bundleExists: { _ in true }
        )
        let blob = String(describing: presentation)
        XCTAssertFalse(blob.contains(sensitiveTicketKey))
        XCTAssertFalse(blob.contains(sensitiveTitle))
        XCTAssertFalse(blob.contains(sensitiveStatus))
        XCTAssertFalse(blob.contains("jira"))
        XCTAssertFalse(blob.contains("mergeRequest"))
        XCTAssertFalse(blob.contains("merge_request"))
        // Sentinels exist only as local test constants.
        XCTAssertEqual(sensitiveTicketKey, "SENSITIVE_TICKET_KEY")
        XCTAssertEqual(sensitiveTitle, "SENSITIVE_TITLE")
        XCTAssertEqual(sensitiveStatus, "SENSITIVE_STATUS")
    }
}
