import Darwin
import XCTest
@testable import Console

@MainActor
final class LocalCommandExecutorTests: XCTestCase {

    private var originalConfirmation: Any?
    private var originalAuthorizeAll: Any?
    private var originalFailureBehavior: Any?
    private var tempDirectories: [URL] = []
    private var pidsToReap: [pid_t] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 30
        originalConfirmation = UserDefaults.standard.object(forKey: "requireConfirmationForDangerous")
        originalAuthorizeAll = UserDefaults.standard.object(forKey: "requireAuthorizationForAllCommands")
        originalFailureBehavior = UserDefaults.standard.object(forKey: "commandFailureBehavior")
        UserDefaults.standard.set(true, forKey: "requireConfirmationForDangerous")
        UserDefaults.standard.set(false, forKey: "requireAuthorizationForAllCommands")
        UserDefaults.standard.set(
            AppSettings.CommandFailureBehavior.stopOnError.rawValue,
            forKey: "commandFailureBehavior"
        )
        tempDirectories = []
        pidsToReap = []
    }

    override func tearDown() {
        for pid in pidsToReap {
            if pid > 1, pid != getpid(), pid != getppid() {
                _ = kill(pid, SIGKILL)
            }
        }
        pidsToReap.removeAll()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        restore(originalConfirmation, key: "requireConfirmationForDangerous")
        restore(originalAuthorizeAll, key: "requireAuthorizationForAllCommands")
        restore(originalFailureBehavior, key: "commandFailureBehavior")
        super.tearDown()
    }

    func testMarkedDangerousCommandRequestsAuthorization() async {
        let authorizer = AuthorizationSpy(shouldAuthorize: true)
        let actions = ActionExecutorSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        let command = makeAppleScriptCommand(
            name: "Synthetic Executor Marked",
            payload: Self.dangerousAppleScriptFixture,
            requiresConfirmation: true
        )

        let run = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(run.result.overallSuccess)
        XCTAssertFalse(run.result.authorizationDenied)
    }

    func testDangerousEditWithoutFlagStillRequestsAuthorization() async {
        let authorizer = AuthorizationSpy(shouldAuthorize: true)
        let actions = ActionExecutorSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        let command = makeAppleScriptCommand(
            name: "Synthetic Executor Unmarked",
            payload: Self.dangerousAppleScriptFixture,
            requiresConfirmation: false
        )

        let run = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(run.result.overallSuccess)
        XCTAssertFalse(command.requiresConfirmation)
    }

    func testDenialProducesZeroActionExecutions() async {
        let authorizer = AuthorizationSpy(shouldAuthorize: false)
        let actions = ActionExecutorSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        let command = makeAppleScriptCommand(
            name: "Synthetic Executor Denied",
            payload: Self.dangerousAppleScriptFixture,
            requiresConfirmation: true
        )

        let run = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(actions.executionCount, 0)
        XCTAssertTrue(run.result.authorizationDenied)
        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertTrue(run.result.logs.isEmpty)
        XCTAssertEqual(executor.completedRunCount, 1)
        XCTAssertFalse(executor.isExecuting)
    }

    func testSafeCommandDoesNotRequestAuthorization() async {
        let authorizer = AuthorizationSpy(shouldAuthorize: true)
        let actions = ActionExecutorSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        let command = makeAppleScriptCommand(
            name: "Synthetic Executor Safe",
            payload: Self.safeAppleScriptFixture,
            requiresConfirmation: false
        )

        let run = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(run.result.overallSuccess)
        XCTAssertFalse(run.result.authorizationDenied)
    }

    func testSkipAuthorizationDoesNotAskAgain() async {
        let authorizer = AuthorizationSpy(shouldAuthorize: true)
        let actions = ActionExecutorSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        let command = makeAppleScriptCommand(
            name: "Synthetic Executor Skip",
            payload: Self.dangerousAppleScriptFixture,
            requiresConfirmation: true
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(run.result.overallSuccess)
    }

    func testDisabledConfirmationPreferenceSkipsDialog() async {
        UserDefaults.standard.set(false, forKey: "requireConfirmationForDangerous")
        let authorizer = AuthorizationSpy(shouldAuthorize: true)
        let actions = ActionExecutorSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        let command = makeAppleScriptCommand(
            name: "Synthetic Executor Preference Off",
            payload: Self.dangerousAppleScriptFixture,
            requiresConfirmation: true
        )

        let run = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(run.result.overallSuccess)
    }

    // MARK: - Overlapping runs

    func testOverlappingExecuteReturnsAlreadyRunningWithoutStartingActions() async {
        let actions = GatingActionExecutor()
        let executor = makeExecutor(actions: actions)
        defer { actions.resume() }
        let firstCommand = makeSafeCommand(name: "Synthetic Overlap First")
        let secondCommand = makeSafeCommand(name: "Synthetic Overlap Second")

        let firstTask = Task { await executor.execute(firstCommand, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await firstTask.value
            return
        }

        let second = await executor.execute(secondCommand, skipAuthorization: true)

        XCTAssertTrue(second.result.alreadyRunning)
        XCTAssertEqual(second.result.command.name, "Synthetic Overlap Second")
        XCTAssertTrue(second.result.logs.isEmpty)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertEqual(executor.completedRunCount, 0)
        XCTAssertTrue(executor.isExecuting)
        XCTAssertNotNil(executor.activeRunID)

        actions.resume()
        let first = await firstTask.value
        XCTAssertFalse(first.result.alreadyRunning)
        XCTAssertTrue(first.result.overallSuccess)
        XCTAssertEqual(first.result.command.name, "Synthetic Overlap First")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(executor.completedRunCount, 1)
        XCTAssertEqual(executor.lastRunID, first.id)
        XCTAssertFalse(executor.isExecuting)
        XCTAssertNil(executor.activeRunID)
    }

    func testOverlappingExecuteDoesNotClearIsExecuting() async {
        let actions = GatingActionExecutor()
        let executor = makeExecutor(actions: actions)
        defer { actions.resume() }
        let firstCommand = makeSafeCommand(name: "Synthetic Occupied First")
        let secondCommand = makeSafeCommand(name: "Synthetic Occupied Second")

        let firstTask = Task { await executor.execute(firstCommand, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await firstTask.value
            return
        }

        _ = await executor.execute(secondCommand, skipAuthorization: true)
        XCTAssertTrue(executor.isExecuting)

        actions.resume()
        _ = await firstTask.value
        XCTAssertFalse(executor.isExecuting)
    }

    func testOverlappingExecuteDoesNotResetCancellation() async {
        let actions = GatingActionExecutor()
        let executor = makeExecutor(actions: actions)
        defer { actions.resume() }
        let firstCommand = makeSafeCommand(
            name: "Synthetic Cancel First",
            actionCount: 2
        )
        let secondCommand = makeSafeCommand(name: "Synthetic Cancel Second")

        let firstTask = Task { await executor.execute(firstCommand, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await firstTask.value
            return
        }

        executor.cancelExecution()
        let second = await executor.execute(secondCommand, skipAuthorization: true)
        XCTAssertTrue(second.result.alreadyRunning)
        XCTAssertTrue(executor.isExecuting)

        actions.resume()
        let first = await firstTask.value
        XCTAssertFalse(first.result.overallSuccess)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertEqual(executor.completedRunCount, 1)
        XCTAssertFalse(executor.isExecuting)
    }

    func testInitiatingCallerReceivesOwnResultNotLaterRun() async {
        let actions = GatingActionExecutor()
        let executor = makeExecutor(actions: actions)
        defer { actions.resume() }
        let firstCommand = makeSafeCommand(name: "Synthetic Own Result First")
        let secondCommand = makeSafeCommand(name: "Synthetic Own Result Second")

        let firstTask = Task { await executor.execute(firstCommand, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await firstTask.value
            return
        }

        let second = await executor.execute(secondCommand, skipAuthorization: true)
        XCTAssertTrue(second.result.alreadyRunning)
        XCTAssertEqual(second.result.command.name, "Synthetic Own Result Second")
        XCTAssertNil(executor.lastResult)

        actions.resume()
        let first = await firstTask.value
        XCTAssertEqual(first.result.command.name, "Synthetic Own Result First")
        XCTAssertFalse(first.result.alreadyRunning)
        XCTAssertEqual(executor.lastResult?.command.name, "Synthetic Own Result First")
        XCTAssertNotEqual(executor.lastRunID, second.id)
    }

    func testOneOccupiedRunEmitsOneCompletion() async {
        let actions = GatingActionExecutor()
        let executor = makeExecutor(actions: actions)
        defer { actions.resume() }
        let firstCommand = makeSafeCommand(name: "Synthetic Completion First")
        let secondCommand = makeSafeCommand(name: "Synthetic Completion Second")

        let firstTask = Task { await executor.execute(firstCommand, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await firstTask.value
            return
        }

        _ = await executor.execute(secondCommand, skipAuthorization: true)
        XCTAssertEqual(executor.completedRunCount, 0)

        actions.resume()
        _ = await firstTask.value
        XCTAssertEqual(executor.completedRunCount, 1)

        let third = await executor.execute(makeSafeCommand(name: "Synthetic Completion Third"), skipAuthorization: true)
        XCTAssertTrue(third.result.overallSuccess)
        XCTAssertEqual(executor.completedRunCount, 2)
    }

    func testBusyRejectDoesNotRequestAuthorization() async {
        let authorizer = AuthorizationSpy(shouldAuthorize: true)
        let actions = GatingActionExecutor()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: authorizer)
        defer { actions.resume() }
        let firstCommand = makeSafeCommand(name: "Synthetic Busy Auth First")
        let secondCommand = makeAppleScriptCommand(
            name: "Synthetic Busy Auth Second",
            payload: Self.dangerousAppleScriptFixture,
            requiresConfirmation: true
        )

        let firstTask = Task { await executor.execute(firstCommand, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await firstTask.value
            return
        }

        let second = await executor.execute(secondCommand)
        XCTAssertTrue(second.result.alreadyRunning)
        XCTAssertEqual(authorizer.requestCount, 0)

        actions.resume()
        _ = await firstTask.value
    }

    // MARK: - Stop and timeouts

    func testStopInterruptsLongRunningCommandAndSkipsLaterAction() async throws {
        let fixture = try makeSleepFixture()
        let later = fixture.directory.appendingPathComponent("later")
        let executor = LocalCommandExecutor(
            actionExecutor: ActionExecutor(),
            authorizer: AuthorizationSpy(shouldAuthorize: true)
        )
        let command = makeShellCommand(
            name: "Synthetic Stop Long",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: fixture.payload,
                    order: 0,
                    delayAfterMS: 0,
                    timeoutMS: 60_000
                ),
                CommandAction(
                    type: .shell,
                    payload: "touch \(later.path)",
                    order: 1,
                    delayAfterMS: 0,
                    timeoutMS: 5_000
                )
            ]
        )

        let start = Date()
        let task = Task { await executor.execute(command, skipAuthorization: true) }
        let pid = try await waitForOwnedPID(fixture.pidFile)
        XCTAssertTrue(executor.isExecuting)
        executor.cancelExecution()
        let run = await task.value

        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertFalse(run.result.alreadyRunning)
        XCTAssertEqual(run.result.logs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.path))
        XCTAssertFalse(OwnedProcessTree.isRunning(pid))
        XCTAssertFalse(executor.isExecuting)
        XCTAssertNil(executor.activeRunID)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testShortTimeoutTerminatesAndReportsTimeout() async throws {
        let fixture = try makeSleepFixture()
        let executor = LocalCommandExecutor(
            actionExecutor: ActionExecutor(),
            authorizer: AuthorizationSpy(shouldAuthorize: true)
        )
        let command = makeShellCommand(
            name: "Synthetic Timeout",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: fixture.payload,
                    order: 0,
                    delayAfterMS: 0,
                    timeoutMS: 250
                )
            ]
        )

        let start = Date()
        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertEqual(run.result.logs.count, 1)
        XCTAssertTrue(
            run.result.logs[0].message.localizedCaseInsensitiveContains("timeout"),
            "Expected Timeout in log, got \(run.result.logs[0].message)"
        )
        XCTAssertFalse(executor.isExecuting)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        if let pid = readPID(from: fixture.pidFile) {
            pidsToReap.append(pid)
            XCTAssertFalse(OwnedProcessTree.isRunning(pid))
        }
    }

    func testNextCommandRunsAfterStopAndOldCancelCannotAffectIt() async throws {
        let firstFixture = try makeSleepFixture()
        let secondFixture = try makeSleepFixture()
        let executor = LocalCommandExecutor(
            actionExecutor: ActionExecutor(),
            authorizer: AuthorizationSpy(shouldAuthorize: true)
        )

        let first = makeShellCommand(
            name: "Synthetic First Stop",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: firstFixture.payload,
                    order: 0,
                    delayAfterMS: 0,
                    timeoutMS: 60_000
                )
            ]
        )
        let firstTask = Task { await executor.execute(first, skipAuthorization: true) }
        _ = try await waitForOwnedPID(firstFixture.pidFile)
        executor.cancelExecution()
        let firstRun = await firstTask.value
        XCTAssertFalse(firstRun.result.overallSuccess)
        XCTAssertFalse(executor.isExecuting)

        executor.cancelExecution()

        let second = makeShellCommand(
            name: "Synthetic Second After Stop",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: "pwd",
                    order: 0,
                    delayAfterMS: 0,
                    timeoutMS: 5_000
                )
            ]
        )
        let secondRun = await executor.execute(second, skipAuthorization: true)
        XCTAssertTrue(secondRun.result.overallSuccess)
        XCTAssertNotEqual(secondRun.id, firstRun.id)
        XCTAssertEqual(executor.lastRunID, secondRun.id)
        XCTAssertEqual(executor.completedRunCount, 2)

        let third = makeShellCommand(
            name: "Synthetic Third Independent",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: secondFixture.payload,
                    order: 0,
                    delayAfterMS: 0,
                    timeoutMS: 60_000
                )
            ]
        )
        let thirdTask = Task { await executor.execute(third, skipAuthorization: true) }
        _ = try await waitForOwnedPID(secondFixture.pidFile)
        XCTAssertTrue(executor.isExecuting)
        XCTAssertNotEqual(executor.activeRunID, firstRun.id)
        executor.cancelExecution()
        let thirdRun = await thirdTask.value
        XCTAssertFalse(thirdRun.result.overallSuccess)
        XCTAssertFalse(executor.isExecuting)
    }

    func testStopDuringPostActionDelaySkipsLaterAction() async throws {
        let later = try makeTempDirectory().appendingPathComponent("later")
        let executor = LocalCommandExecutor(
            actionExecutor: ActionExecutor(),
            authorizer: AuthorizationSpy(shouldAuthorize: true)
        )
        let command = makeShellCommand(
            name: "Synthetic Delay Stop",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: "pwd",
                    order: 0,
                    delayAfterMS: 8_000,
                    timeoutMS: 5_000
                ),
                CommandAction(
                    type: .shell,
                    payload: "touch \(later.path)",
                    order: 1,
                    delayAfterMS: 0,
                    timeoutMS: 5_000
                )
            ]
        )

        let start = Date()
        let task = Task { await executor.execute(command, skipAuthorization: true) }
        guard await waitUntil({ executor.isExecuting }) else {
            _ = await task.value
            return
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        executor.cancelExecution()
        let run = await task.value

        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(executor.isExecuting)
    }

    // MARK: - Retry, fallback, completion checks

    func testRetryingFakeActionFailsTwiceThenSucceedsOnConfiguredAttempt() async {
        let actions = SequenceActionExecutor(results: [
            .failure(ActionExecutionError.appleScriptError("synthetic fail 1")),
            .failure(ActionExecutionError.appleScriptError("synthetic fail 2")),
            .success("ok")
        ])
        let executor = makeExecutor(actions: actions)
        let command = makePolicyCommand(
            name: "Synthetic Retry Then Succeed",
            action: CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: 0,
                delayAfterMS: 0,
                retryOnFailure: true,
                maxRetries: 3
            )
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(actions.executionCount, 3)
        XCTAssertEqual(actions.payloads, [Self.safeAppleScriptFixture, Self.safeAppleScriptFixture, Self.safeAppleScriptFixture])
        XCTAssertTrue(run.result.overallSuccess)
        XCTAssertEqual(run.result.logs.count, 1)
        XCTAssertTrue(run.result.logs[0].isSuccess)
        XCTAssertTrue(run.result.logs[0].message.contains("attempt 3"), run.result.logs[0].message)
    }

    func testRetryStaysOffWhenMaxRetriesIsSetButFlagIsFalse() async {
        let actions = SequenceActionExecutor(results: [
            .failure(ActionExecutionError.appleScriptError("synthetic fail")),
            .success("should not run")
        ])
        let executor = makeExecutor(actions: actions)
        let command = makePolicyCommand(
            name: "Synthetic Retry Off",
            action: CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: 0,
                delayAfterMS: 0,
                retryOnFailure: false,
                maxRetries: 5
            )
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertFalse(run.result.logs[0].isSuccess)
    }

    func testFallbackRunsOnlyAfterPrimaryAttemptsExhausted() async {
        let actions = SequenceActionExecutor(results: [
            .failure(ActionExecutionError.appleScriptError("synthetic fail 1")),
            .failure(ActionExecutionError.appleScriptError("synthetic fail 2")),
            .success("fallback-ok")
        ])
        let executor = makeExecutor(actions: actions)
        let fallbackPayload = "return \"fallback\""
        let command = makePolicyCommand(
            name: "Synthetic Fallback After Exhaustion",
            action: CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: 0,
                delayAfterMS: 0,
                retryOnFailure: true,
                maxRetries: 2,
                fallbackAction: FallbackAction(type: .appleScript, payload: fallbackPayload)
            )
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(actions.executionCount, 3)
        XCTAssertEqual(actions.payloads, [
            Self.safeAppleScriptFixture,
            Self.safeAppleScriptFixture,
            fallbackPayload
        ])
        XCTAssertTrue(run.result.overallSuccess)
        XCTAssertTrue(run.result.logs[0].message.localizedCaseInsensitiveContains("fallback"), run.result.logs[0].message)
    }

    func testFallbackDoesNotRunAfterCancellationDuringRetry() async {
        let actions = FailThenHoldActionExecutor()
        let executor = makeExecutor(actions: actions)
        defer { actions.resume() }
        let fallbackPayload = "return \"fallback\""
        let command = makePolicyCommand(
            name: "Synthetic Cancel Skips Fallback",
            action: CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: 0,
                delayAfterMS: 0,
                retryOnFailure: true,
                maxRetries: 3,
                fallbackAction: FallbackAction(type: .appleScript, payload: fallbackPayload)
            )
        )

        let task = Task { await executor.execute(command, skipAuthorization: true) }
        guard await waitUntil({ actions.isHolding && executor.isExecuting }) else {
            _ = await task.value
            return
        }
        executor.cancelExecution()
        let run = await task.value

        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertEqual(actions.executionCount, 2)
        XCTAssertFalse(actions.payloads.contains(fallbackPayload))
        XCTAssertFalse(executor.isExecuting)
    }

    func testDisallowedShellCommandIsRejectedWithoutExecuting() async {
        let actions = ActionExecutorSpy()
        let executor = makeExecutor(actions: actions)
        let command = makeShellCommand(
            name: "Synthetic Executor Disallowed Shell",
            actions: [
                CommandAction(
                    type: .shell,
                    payload: ShellPayload(command: "/bin/echo", args: ["synthetic"]).encodedJSONString(),
                    order: 0
                )
            ]
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(actions.executionCount, 0)
        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertEqual(run.result.logs.count, 1)
        XCTAssertFalse(run.result.logs[0].isSuccess)
        XCTAssertTrue(
            run.result.logs[0].message.localizedCaseInsensitiveContains("not allowed"),
            run.result.logs[0].message
        )
        XCTAssertFalse(executor.isExecuting)
    }

    func testInvalidFallbackIsRejectedWithoutExecutingIt() async {
        let actions = SequenceActionExecutor(results: [
            .failure(ActionExecutionError.appleScriptError("synthetic fail"))
        ])
        let executor = makeExecutor(actions: actions)
        let command = makePolicyCommand(
            name: "Synthetic Invalid Fallback Runtime",
            action: CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: 0,
                delayAfterMS: 0,
                retryOnFailure: false,
                fallbackAction: FallbackAction(type: .appleScript, payload: "   ")
            )
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertEqual(actions.payloads, [Self.safeAppleScriptFixture])
        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertTrue(
            run.result.logs[0].message.localizedCaseInsensitiveContains("fallback"),
            run.result.logs[0].message
        )
        XCTAssertNotEqual(ExecutionResult.failureBannerMessage(from: run.result.logs), "Unknown error")
    }

    func testCompletionTimeoutProducesFailedRowAndActionableBanner() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-review-17-missing-\(UUID().uuidString)")
        let actions = ActionExecutorSpy()
        let executor = makeExecutor(actions: actions)
        let command = makePolicyCommand(
            name: "Synthetic Completion Timeout",
            action: CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: 0,
                delayAfterMS: 0,
                timeoutMS: 250,
                completionCheck: .fileExists(missing.path)
            )
        )

        let start = Date()
        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertEqual(run.result.logs.count, 2)
        XCTAssertTrue(run.result.logs[0].isSuccess)
        let checkLog = run.result.logs[1]
        XCTAssertEqual(checkLog.kind, .completionCheck)
        XCTAssertFalse(checkLog.isSuccess)
        XCTAssertEqual(checkLog.completionCheck?.type, .fileExists)
        XCTAssertEqual(checkLog.completionCheck?.outcome, .timedOut)
        XCTAssertGreaterThan(checkLog.completionCheck?.elapsedMs ?? 0, 0)
        XCTAssertTrue(checkLog.message.localizedCaseInsensitiveContains("timed out"), checkLog.message)
        XCTAssertTrue(checkLog.message.contains("fileExists"), checkLog.message)
        XCTAssertTrue(checkLog.message.contains("250"), checkLog.message)
        let banner = ExecutionResult.failureBannerMessage(from: run.result.logs)
        XCTAssertEqual(banner, checkLog.message)
        XCTAssertNotEqual(banner, "Unknown error")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testContinueOnErrorRunsLaterActionAfterCompletionTimeout() async {
        UserDefaults.standard.set(
            AppSettings.CommandFailureBehavior.continueOnError.rawValue,
            forKey: "commandFailureBehavior"
        )
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-review-17-missing-\(UUID().uuidString)")
        let laterPayload = "return \"later\""
        let actions = SequenceActionExecutor(results: [
            .success("ok"),
            .success("later-ok")
        ])
        let executor = makeExecutor(actions: actions)
        let command = Command(
            name: "Synthetic Continue After Check",
            triggerPhrases: ["synthetic executor policy"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: Self.safeAppleScriptFixture,
                    order: 0,
                    delayAfterMS: 0,
                    timeoutMS: 200,
                    completionCheck: .fileExists(missing.path)
                ),
                CommandAction(
                    type: .appleScript,
                    payload: laterPayload,
                    order: 1,
                    delayAfterMS: 0
                )
            ],
            executionMode: .appleScript,
            requiresConfirmation: false
        )

        let run = await executor.execute(command, skipAuthorization: true)

        XCTAssertFalse(run.result.overallSuccess)
        XCTAssertEqual(actions.payloads, [Self.safeAppleScriptFixture, laterPayload])
        XCTAssertEqual(run.result.logs.count, 3)
        XCTAssertTrue(run.result.logs[2].isSuccess)
        XCTAssertNotEqual(ExecutionResult.failureBannerMessage(from: run.result.logs), "Unknown error")
    }

    // MARK: - Helpers

    private func makeExecutor(actions: any CommandActionExecuting) -> LocalCommandExecutor {
        LocalCommandExecutor(actionExecutor: actions, authorizer: AuthorizationSpy(shouldAuthorize: true))
    }

    private func makeSafeCommand(name: String, actionCount: Int = 1) -> Command {
        let actions = (0..<actionCount).map { index in
            CommandAction(
                type: .appleScript,
                payload: Self.safeAppleScriptFixture,
                order: index,
                delayAfterMS: 0
            )
        }
        return Command(
            name: name,
            triggerPhrases: ["synthetic executor overlap"],
            actions: actions,
            executionMode: .appleScript,
            requiresConfirmation: false
        )
    }

    private func makePolicyCommand(name: String, action: CommandAction) -> Command {
        Command(
            name: name,
            triggerPhrases: ["synthetic executor policy"],
            actions: [action],
            executionMode: .appleScript,
            requiresConfirmation: false
        )
    }

    @discardableResult
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        let satisfied = condition()
        XCTAssertTrue(satisfied, "Timed out waiting for condition", file: file, line: line)
        return satisfied
    }

    private func makeAppleScriptCommand(
        name: String,
        payload: String,
        requiresConfirmation: Bool
    ) -> Command {
        Command(
            name: name,
            triggerPhrases: ["synthetic executor"],
            actions: [
                CommandAction(type: .appleScript, payload: payload, order: 0)
            ],
            executionMode: .appleScript,
            requiresConfirmation: requiresConfirmation
        )
    }

    private func makeShellCommand(name: String, actions: [CommandAction]) -> Command {
        Command(
            name: name,
            triggerPhrases: ["synthetic executor stop"],
            actions: actions,
            executionMode: .mixed,
            requiresConfirmation: false
        )
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCommandExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeSleepFixture() throws -> (directory: URL, payload: String, pidFile: URL) {
        let directory = try makeTempDirectory()
        let pidFile = directory.appendingPathComponent("pid")
        // python3 is on the shell allowlist; the interpreter itself sleeps so the
        // executor owns a live child to interrupt. Absolute-path scripts are not
        // allowlisted and are rejected before launch.
        let payload = """
        python3 -c 'import os,sys,time; open(sys.argv[1], "w").write(str(os.getpid())); time.sleep(60)' \(pidFile.path)
        """
        return (directory, payload, pidFile)
    }

    private func waitForOwnedPID(_ url: URL, timeout: TimeInterval = 2) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = readPID(from: url) {
                pidsToReap.append(pid)
                return pid
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for pid file at \(url.path)")
        throw NSError(domain: "LocalCommandExecutorTests", code: 1)
    }

    private func readPID(from url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = pid_t(trimmed), value > 1 else { return nil }
        return value
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Inert AppleScript. If executed it only returns a string.
    private static let safeAppleScriptFixture = "return \"ok\""

    /// Inert AppleScript whose source contains a dangerous token so validation flags it.
    /// The token lives in a comment; the script only returns a string. Tests never execute it.
    private static let dangerousAppleScriptFixture = """
    -- synthetic fixture: rm -rf
    return "ok"
    """
}

@MainActor
private final class AuthorizationSpy: CommandAuthorizing {
    var shouldAuthorize: Bool
    private(set) var requestCount = 0

    init(shouldAuthorize: Bool) {
        self.shouldAuthorize = shouldAuthorize
    }

    func requestAuthorization(for command: Command) async -> Bool {
        requestCount += 1
        return shouldAuthorize
    }
}

private final class ActionExecutorSpy: CommandActionExecuting {
    private(set) var executionCount = 0

    func execute(_ action: CommandAction) async throws -> String {
        executionCount += 1
        return "ok"
    }
}

private final class GatingActionExecutor: CommandActionExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _executionCount = 0
    private var _isHolding = false
    private var continuation: CheckedContinuation<String, Error>?

    var executionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _executionCount
    }

    var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isHolding
    }

    func execute(_ action: CommandAction) async throws -> String {
        let shouldHold: Bool = {
            lock.lock(); defer { lock.unlock() }
            _executionCount += 1
            return _executionCount == 1
        }()
        if shouldHold {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self._isHolding = true
                lock.unlock()
            }
        }
        return "ok"
    }

    func resume(with output: String = "ok") {
        lock.lock()
        let pending = continuation
        continuation = nil
        _isHolding = false
        lock.unlock()
        pending?.resume(returning: output)
    }
}

private final class SequenceActionExecutor: CommandActionExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Result<String, Error>]
    private var _payloads: [String] = []
    private var _executionCount = 0

    var payloads: [String] {
        lock.lock(); defer { lock.unlock() }
        return _payloads
    }

    var executionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _executionCount
    }

    init(results: [Result<String, Error>]) {
        remaining = results
    }

    func execute(_ action: CommandAction) async throws -> String {
        lock.lock()
        _executionCount += 1
        _payloads.append(action.payload)
        let next: Result<String, Error>
        if remaining.isEmpty {
            next = .failure(ActionExecutionError.appleScriptError("synthetic exhausted"))
        } else {
            next = remaining.removeFirst()
        }
        lock.unlock()
        switch next {
        case .success(let output):
            return output
        case .failure(let error):
            throw error
        }
    }
}

private final class FailThenHoldActionExecutor: CommandActionExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var continuation: CheckedContinuation<String, Error>?
    private var _payloads: [String] = []
    private var _isHolding = false

    var executionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isHolding
    }

    var payloads: [String] {
        lock.lock(); defer { lock.unlock() }
        return _payloads
    }

    func execute(_ action: CommandAction) async throws -> String {
        let attempt: Int = {
            lock.lock(); defer { lock.unlock() }
            count += 1
            _payloads.append(action.payload)
            return count
        }()
        if attempt == 1 {
            throw ActionExecutionError.appleScriptError("synthetic first fail")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self._isHolding = true
                self.lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            let pending = self.continuation
            self.continuation = nil
            self._isHolding = false
            self.lock.unlock()
            pending?.resume(throwing: CancellationError())
        }
    }

    func resume(with output: String = "ok") {
        lock.lock()
        let pending = continuation
        continuation = nil
        _isHolding = false
        lock.unlock()
        pending?.resume(returning: output)
    }
}
