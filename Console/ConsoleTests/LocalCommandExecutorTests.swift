import XCTest
@testable import Console

@MainActor
final class LocalCommandExecutorTests: XCTestCase {

    private var originalConfirmation: Any?
    private var originalAuthorizeAll: Any?

    override func setUp() {
        super.setUp()
        originalConfirmation = UserDefaults.standard.object(forKey: "requireConfirmationForDangerous")
        originalAuthorizeAll = UserDefaults.standard.object(forKey: "requireAuthorizationForAllCommands")
        UserDefaults.standard.set(true, forKey: "requireConfirmationForDangerous")
        UserDefaults.standard.set(false, forKey: "requireAuthorizationForAllCommands")
    }

    override func tearDown() {
        restore(originalConfirmation, key: "requireConfirmationForDangerous")
        restore(originalAuthorizeAll, key: "requireAuthorizationForAllCommands")
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
