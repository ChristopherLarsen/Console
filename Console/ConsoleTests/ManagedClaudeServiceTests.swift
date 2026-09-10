import XCTest
@testable import Console

/// Unit/integration tests for the Console-managed headless Claude service
/// (`ClaudeAccess`). The transport is faked; `prepare()`'s real `--help`
/// probe runs against a stub executable so no host installation is needed.
@MainActor
final class ManagedClaudeServiceTests: XCTestCase {

    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var service: ManagedClaudeService!
    private var transport: FakeHeadlessTransport!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedClaudeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ManagedClaudeServiceTests-\(UUID().uuidString)")
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

    private func pingInvocation(deadline: TimeInterval = 5) -> ClaudeOperationInvocation {
        let correlationID = UUID()
        return ClaudeOperationInvocation(
            correlationID: correlationID,
            prompt: """
            Reply with only this JSON object, nothing else:
            {"schemaVersion":1,"correlationID":"\(correlationID.uuidString)","operation":"ping"}
            """,
            ephemeral: true,
            deadline: Date().addingTimeInterval(deadline)
        )
    }

    // MARK: Preparation

    func testPrepareValidatesFlagsAndCreatesWorkingDirectory() async throws {
        let prepared = await service.prepare()
        XCTAssertTrue(prepared)
        XCTAssertEqual(service.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appending(path: "workspace").path))
        XCTAssertEqual(service.supportedFlags?.contains("--print"), true)
    }

    func testPrepareFailsWhenMandatoryFlagMissing() async throws {
        let helpWithoutOutputFormat = StubCLI.helpOutput
            .replacingOccurrences(of: "--output-format <format>", with: "--output-format-alias <format>")
        let stub = try StubCLI.makeExecutable(directory: tempDirectory, helpText: helpWithoutOutputFormat)
        let locator = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [stub] },
            defaults: defaults
        )
        let strictService = ManagedClaudeService(
            transport: transport,
            locator: locator,
            configuration: ManagedClaudeConfiguration(workingDirectoryPath: tempDirectory.path),
            defaults: defaults
        )
        let prepared = await strictService.prepare()
        XCTAssertFalse(prepared)
        guard case .error = strictService.state else { return XCTFail("expected error state") }
    }

    // MARK: perform plumbing

    func testPerformPipesPromptViaStdinAndParsesEnvelope() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "ping", correlationID: UUID()))
        _ = await service.prepare()
        let invocation = pingInvocation()
        let output = try await service.perform(invocation)

        XCTAssertEqual(output.correlationID, invocation.correlationID)
        XCTAssertEqual(output.sessionID?.uuidString, "22222222-2222-2222-2222-222222222222")

        let request = transport.requests.last { $0.arguments != ["--help"] }
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.standardInputText, invocation.prompt)
        // The prompt never travels in argv.
        XCTAssertFalse(request?.arguments.contains(invocation.prompt) ?? true)
        XCTAssertEqual(request?.workingDirectory, tempDirectory.appending(path: "workspace").path)
    }

    func testManagedRunsNeverUseContinueAndPinMCP() async throws {
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "ping", correlationID: UUID()))
        transport.enqueueSuccess(result: StubCLI.structuredResult(operation: "ping", correlationID: UUID()))
        _ = await service.prepare()
        _ = try await service.perform(pingInvocation())
        _ = try await service.perform(pingInvocation())
        let flattened = transport.requests.flatMap { $0.arguments }
        XCTAssertFalse(flattened.contains("--continue"), "--continue (latest session) is never used")
        XCTAssertTrue(flattened.contains("--strict-mcp-config"))
    }

    // MARK: Serial execution

    func testOperationsRunOneAtATime() async throws {
        for _ in 0..<3 {
            transport.enqueueBehavior { _ in
                try? await Task.sleep(nanoseconds: 25_000_000)
                return .success(stdout: StubCLI.envelope(promptText: ""), stderr: nil)
            }
        }
        _ = await service.prepare()
        try await withThrowingTaskGroup(of: ClaudeOperationOutput.self) { group in
            for _ in 0..<3 {
                group.addTask { try await self.service.perform(self.pingInvocation()) }
            }
            while try await group.next() != nil {}
        }
        XCTAssertTrue(transport.concurrencyCapped(at: 1), "managed operations must be serial")
        XCTAssertEqual(transport.requests.count, 3, "only the three operations; the --help probe runs directly against the stub executable")
        XCTAssertEqual(service.state, .ready)
    }

    // MARK: interpret() classification

    func testInterpretMapsTimeoutAndCancellation() throws {
        let invocation = pingInvocation()
        XCTAssertThrowsError(try ManagedClaudeService.interpret(
            outcome: ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .timedOut),
            invocation: invocation
        )) { error in
            XCTAssertEqual(error as? ClaudeServiceError, .timedOut(correlationID: invocation.correlationID))
        }
        XCTAssertThrowsError(try ManagedClaudeService.interpret(
            outcome: ClaudeHeadlessOutcome(dispatched: true, stdout: nil, stderr: nil, failure: .cancelled),
            invocation: invocation
        )) { error in
            XCTAssertEqual(error as? ClaudeServiceError, .cancelled)
        }
    }

    func testInterpretMapsAuthFailureAndNonZeroExit() throws {
        XCTAssertThrowsError(try ManagedClaudeService.interpret(
            outcome: ClaudeHeadlessOutcome(
                dispatched: true, stdout: nil,
                stderr: "Error: Invalid API key · please run /login",
                failure: .authenticationRequired(reason: "Invalid API key")
            ),
            invocation: pingInvocation()
        )) { error in
            guard case .needsAuthentication = error as? ClaudeServiceError else {
                return XCTFail("expected needsAuthentication, got \(error)")
            }
        }

        XCTAssertThrowsError(try ManagedClaudeService.interpret(
            outcome: ClaudeHeadlessOutcome(
                dispatched: true, stdout: nil, stderr: "boom",
                failure: .nonZeroExit(code: 1, message: "boom")
            ),
            invocation: pingInvocation()
        )) { error in
            guard case .executionFailed = error as? ClaudeServiceError else {
                return XCTFail("expected executionFailed, got \(error)")
            }
        }
    }

    func testInterpretRejectsMalformedAndErrorEnvelopes() throws {
        XCTAssertThrowsError(try ManagedClaudeService.interpret(
            outcome: .success(stdout: "this is not json", stderr: nil),
            invocation: pingInvocation()
        )) { error in
            guard case .malformedOutput = error as? ClaudeServiceError else {
                return XCTFail("expected malformedOutput, got \(error)")
            }
        }
        XCTAssertThrowsError(try ManagedClaudeService.interpret(
            outcome: .success(
                stdout: StubCLI.envelope(promptText: "", resultOverride: "refused", isError: true),
                stderr: nil
            ),
            invocation: pingInvocation()
        )) { error in
            guard case .executionFailed = error as? ClaudeServiceError else {
                return XCTFail("expected executionFailed, got \(error)")
            }
        }
    }

    // MARK: Lifecycle

    func testCleanupForAppQuitStopsServiceAndRefusesWork() async throws {
        transport.hangNextRun()
        _ = await service.prepare()
        let task = Task { try await service.perform(pingInvocation(deadline: 30)) }
        try await Task.sleep(nanoseconds: 100_000_000)

        service.cleanupForAppQuit()
        XCTAssertEqual(service.state, .stopped)

        do {
            _ = try await service.perform(pingInvocation())
            XCTFail("expected refusal after cleanup")
        } catch let error as ClaudeServiceError {
            XCTAssertEqual(error, .shuttingDown)
        }
        transport.release()
        _ = try? await task.value
    }
}
