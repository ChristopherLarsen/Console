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

        let result = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(result.overallSuccess)
        XCTAssertFalse(result.authorizationDenied)
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

        let result = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(result.overallSuccess)
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

        let result = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(actions.executionCount, 0)
        XCTAssertTrue(result.authorizationDenied)
        XCTAssertFalse(result.overallSuccess)
        XCTAssertTrue(result.logs.isEmpty)
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

        let result = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(result.overallSuccess)
        XCTAssertFalse(result.authorizationDenied)
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

        let result = await executor.execute(command, skipAuthorization: true)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(result.overallSuccess)
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

        let result = await executor.execute(command)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(actions.executionCount, 1)
        XCTAssertTrue(result.overallSuccess)
    }

    // MARK: - Helpers

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
