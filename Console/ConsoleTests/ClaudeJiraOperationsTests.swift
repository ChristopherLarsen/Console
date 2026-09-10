import XCTest
@testable import Console

/// Tests for `ClaudeJiraOperations`: read validation/retries/coalescing,
/// the write state machine, and unknown-outcome reconciliation — all against
/// a real `ManagedClaudeService` with a faked transport.
@MainActor
final class ClaudeJiraOperationsTests: XCTestCase {

    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var service: ManagedClaudeService!
    private var transport: FakeHeadlessTransport!

    private let personalConnection = JiraConnectionIdentity(hostIdentifier: "personal", boundary: .personalInstance)
    private let companyConnection = JiraConnectionIdentity(hostIdentifier: "company", boundary: .companyInstance)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeJiraOperationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ClaudeJiraOperationsTests-\(UUID().uuidString)")
        let stub = try StubCLI.makeExecutable(directory: tempDirectory)
        let locator = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [stub] },
            defaults: defaults
        )
        transport = FakeHeadlessTransport()
        service = ManagedClaudeService(
            transport: transport,
            locator: locator,
            configuration: ManagedClaudeConfiguration(
                requestTimeout: 10,
                workingDirectoryPath: tempDirectory.appending(path: "workspace").path
            ),
            defaults: defaults
        )
    }

    override func tearDownWithError() throws {
        transport.release()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func operations(connection: JiraConnectionIdentity? = nil) -> ClaudeJiraOperations {
        ClaudeJiraOperations(
            service: service,
            readRetryAttempts: 2,
            connection: connection ?? personalConnection
        )
    }

    private func context(
        connection: JiraConnectionIdentity = JiraConnectionIdentity(hostIdentifier: "personal", boundary: .personalInstance),
        timeout: TimeInterval = 5
    ) -> JiraOperationContext {
        JiraOperationContext(connection: connection, deadline: Date().addingTimeInterval(timeout))
    }

    // MARK: Data boundary

    func testCompanyBoundaryIsRefusedBeforeAnyProcessStarts() async throws {
        do {
            _ = try await operations(connection: companyConnection)
                .currentStatus(of: "PROJ-1", context: context(connection: companyConnection))
            XCTFail("expected policyBlocked")
        } catch let error as JiraOperationsError {
            XCTAssertEqual(error, .policyBlocked(boundary: .companyInstance))
        }
        XCTAssertEqual(transport.requests.count, 0, "no process may start for company-boundary data")
    }

    // MARK: Reads

    func testLookupDecodesValidatedSnapshot() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(
            operation: "lookup",
            correlationID: UUID(), // placeholder; replaced below by prompt echo
            ticketKey: "FIX-1",
            statusName: "In Progress"
        ))
        let snapshot = try await operations().lookupIssue("FIX-1", context: context())
        XCTAssertEqual(snapshot.key, "FIX-1")
        XCTAssertEqual(snapshot.status.name, "In Progress")
    }

    func testLookupRejectsMismatchedTicket() async throws {
        transport.enqueueBehavior { request in
            let structured = StubCLI.structuredResult(
                operation: "lookup",
                correlationID: StubCLI.correlationID(in: request.standardInputText) ?? UUID(),
                ticketKey: "FIX-9",
                statusName: "In Progress"
            )
            return .success(stdout: StubCLI.envelope(promptText: request.standardInputText, resultOverride: structured), stderr: nil)
        }
        do {
            _ = try await operations().lookupIssue("FIX-1", context: context())
            XCTFail("expected mismatchedTicket")
        } catch let error as JiraOperationsError {
            XCTAssertEqual(error, .mismatchedTicket(expected: "FIX-1", received: "FIX-9"))
        }
    }

    func testReadRetriesBoundedTransientFailures() async throws {
        transport.enqueue(ClaudeHeadlessOutcome(
            dispatched: true, stdout: nil, stderr: nil,
            failure: .nonZeroExit(code: 1, message: "transient")
        ))
        transport.enqueueBehavior { request in
            let structured = StubCLI.structuredResult(
                operation: "lookup",
                correlationID: StubCLI.correlationID(in: request.standardInputText) ?? UUID(),
                ticketKey: "FIX-1",
                statusName: "Open"
            )
            return .success(stdout: StubCLI.envelope(promptText: request.standardInputText, resultOverride: structured), stderr: nil)
        }
        let snapshot = try await operations().lookupIssue("FIX-1", context: context())
        XCTAssertEqual(snapshot.status.name, "Open")
        XCTAssertEqual(transport.requests.count, 2, "first attempt failed, bounded retry succeeded")
    }

    func testReadDoesNotRetryAuthenticationFailure() async throws {
        transport.enqueue(ClaudeHeadlessOutcome(
            dispatched: true, stdout: nil,
            stderr: "Error: Invalid API key",
            failure: .authenticationRequired(reason: "Invalid API key")
        ))
        do {
            _ = try await operations().lookupIssue("FIX-1", context: context())
            XCTFail("expected needsAuthentication")
        } catch let error as JiraOperationsError {
            XCTAssertEqual(error, .needsAuthentication)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testIdenticalConcurrentReadsCoalesce() async throws {
        transport.enqueueBehavior { request in
            try? await Task.sleep(nanoseconds: 80_000_000)
            let structured = StubCLI.structuredResult(
                operation: "lookup",
                correlationID: StubCLI.correlationID(in: request.standardInputText) ?? UUID(),
                ticketKey: "FIX-1",
                statusName: "Open"
            )
            return .success(stdout: StubCLI.envelope(promptText: request.standardInputText, resultOverride: structured), stderr: nil)
        }
        let ops = operations()
        async let first = ops.lookupIssue("FIX-1", context: context())
        async let second = ops.lookupIssue("FIX-1", context: context())
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.status.name, "Open")
        XCTAssertEqual(b.status.name, "Open")
        XCTAssertEqual(transport.requests.count, 1, "identical in-flight reads share one run")
    }

    func testSearchBoundsLimit() async throws {
        transport.enqueueBehavior { request in
            let structured = StubCLI.structuredResult(
                operation: "search",
                correlationID: StubCLI.correlationID(in: request.standardInputText) ?? UUID(),
                results: [["key": "FIX-1", "statusName": "Open"], ["key": "FIX-2", "statusName": "Done"]]
            )
            return .success(stdout: StubCLI.envelope(promptText: request.standardInputText, resultOverride: structured), stderr: nil)
        }
        let results = try await operations().searchTickets(matching: "triage", limit: 500, context: context())
        XCTAssertEqual(results.count, 2)
        let prompt = transport.requests.first?.standardInputText ?? ""
        XCTAssertTrue(prompt.contains("up to 50"), "search is bounded regardless of caller input")
    }

    // MARK: Writes

    func testTransitionHappyPathVerifiesWithFreshRead() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "31", "name": "Done", "targetStatusName": "Done"]]))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transition", correlationID: UUID(), ticketKey: "FIX-1", appliedTransitionID: "31"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "Done"))

        let result = try await operations().transition("FIX-1", to: "Done", context: context())
        XCTAssertEqual(result.verified, true)
        XCTAssertEqual(result.reconciled, false)
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testTransitionRejectsAmbiguousOrMissingTargetWithoutWrite() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "21", "name": "Blocked", "targetStatusName": "Blocked"]]))
        do {
            _ = try await operations().transition("FIX-1", to: "Done", context: context())
            XCTFail("expected transitionTargetUnavailable")
        } catch let error as JiraOperationsError {
            guard case .transitionTargetUnavailable = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(transport.requests.count, 2, "no transition may run when the target cannot be resolved exactly")
    }

    func testAmbiguousWriteReconcilesToReconciledSuccess() async throws {
        // lookup, transitions, write turn times out (may have applied),
        // fresh read shows the target status -> reconciled success, no retry.
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "31", "name": "Done", "targetStatusName": "Done"]]))
        transport.enqueue(ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .timedOut))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "Done"))

        let result = try await operations().transition("FIX-1", to: "Done", context: context())
        XCTAssertEqual(result.verified, false)
        XCTAssertEqual(result.reconciled, true)
        XCTAssertEqual(transport.requests.count, 4, "exactly one write turn, then a reconciliation read")
    }

    func testAmbiguousWriteSurfacesVerificationFailureWithoutRetryingWrite() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "31", "name": "Done", "targetStatusName": "Done"]]))
        transport.enqueue(ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .timedOut))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))

        do {
            _ = try await operations().transition("FIX-1", to: "Done", context: context())
            XCTFail("expected verificationFailed")
        } catch let error as JiraOperationsError {
            XCTAssertEqual(error, .verificationFailed(key: "FIX-1", expectedStatusName: "Done", observedStatusName: "In Progress"))
        }
        XCTAssertEqual(transport.requests.count, 4, "the write is never retried automatically")
    }

    func testFailedVerificationReadAfterAcceptedWriteIsUnknownOutcome() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "31", "name": "Done", "targetStatusName": "Done"]]))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transition", correlationID: UUID(), ticketKey: "FIX-1", appliedTransitionID: "31"))
        transport.enqueue(ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .timedOut))

        do {
            _ = try await operations().transition("FIX-1", to: "Done", context: context())
            XCTFail("expected writeOutcomeUnknown")
        } catch let error as JiraOperationsError {
            guard case .writeOutcomeUnknown = error else { return XCTFail("wrong error \(error)") }
        }
        // lookup + transitions + write + verification read tried up to 3
        // times (readRetryAttempts: 2 -> attempts 0...2) before the unknown
        // outcome is surfaced; the write itself was never retried.
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testNotDispatchedWriteFailsAsTransientWithoutReconcileRead() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "31", "name": "Done", "targetStatusName": "Done"]]))
        transport.enqueue(ClaudeHeadlessOutcome(dispatched: false, stdout: nil, stderr: nil, failure: .launchFailed(reason: "binary missing")))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "In Progress"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transitions", correlationID: UUID(), ticketKey: "FIX-1", transitions: [["id": "31", "name": "Done", "targetStatusName": "Done"]]))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "transition", correlationID: UUID(), ticketKey: "FIX-1", appliedTransitionID: "31"))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "lookup", correlationID: UUID(), ticketKey: "FIX-1", statusName: "Done"))

        // Nothing was dispatched, so the whole write flow retries safely:
        // attempt 1 = lookup+transitions+failed launch (3), attempt 2 =
        // lookup+transitions+write+verify read (4). Total 7 transport runs.
        let result = try await operations().transition("FIX-1", to: "Done", context: context(timeout: 30))
        XCTAssertEqual(result.verified, true)
        XCTAssertEqual(transport.requests.count, 7, "one full write flow retried once after a not-dispatched launch failure")
    }

    // MARK: Resolve helper

    func testResolveExactTransitionRequiresUnambiguousMatch() {
        let transitions = [
            JiraTransition(id: "21", name: "Start Progress", targetStatusName: "In Progress"),
            JiraTransition(id: "31", name: "Done", targetStatusName: "done"),
        ]
        XCTAssertEqual(ClaudeJiraOperations.resolveExactTransition(from: transitions, targetStatusName: "DONE")?.id, "31")
        XCTAssertNil(ClaudeJiraOperations.resolveExactTransition(from: transitions, targetStatusName: "Blocked"))
    }
}
