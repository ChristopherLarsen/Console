import XCTest
import SwiftData
@testable import Console

/// X02-F01 — "require authorization for every command" covers console/registry
/// routes. X02-F04 — App Intent execute honors enableBuiltInCommands.
/// H05-F01 — disabled console starters disable their registry twins.
/// H05-F03 — registry and starter alias lists agree.
@MainActor
final class CommandRouteAuthorizationTests: XCTestCase {

    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in ["requireAuthorizationForAllCommands",
                    "requireConfirmationForDangerous",
                    "enableBuiltInCommands",
                    "recognizeBuiltInCommands"] {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "requireConfirmationForDangerous")
        UserDefaults.standard.set(true, forKey: "recognizeBuiltInCommands")
    }

    override func tearDown() {
        for (key, value) in savedDefaults {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - X02-F01: executor gates console actions when auth-all is on

    func testAuthAllGatesConsoleCommandThroughExecutor() async throws {
        UserDefaults.standard.set(true, forKey: "requireAuthorizationForAllCommands")
        let spy = AuthorizationRequestSpy()
        let executor = LocalCommandExecutor(actionExecutor: NoopActionExecutor(), authorizer: spy)
        let command = makeConsoleCommand(action: .fishSettings)

        _ = await executor.execute(command)

        XCTAssertEqual(spy.requestCount, 1, "Console route must honor the every-command gate")
    }

    func testEmergencyStopStaysReachableUnderAuthAll() async throws {
        UserDefaults.standard.set(true, forKey: "requireAuthorizationForAllCommands")
        let spy = AuthorizationRequestSpy()
        let executor = LocalCommandExecutor(actionExecutor: NoopActionExecutor(), authorizer: spy)
        let command = makeConsoleCommand(action: .fishOff)

        _ = await executor.execute(command, skipAuthorization: false)

        XCTAssertEqual(spy.requestCount, 0, "Emergency stop must not be dialog-gated")
        XCTAssertTrue(AuthorizationManager.shared.requiresAuthorization(command) == false)
    }

    func testAuthAllDoesNotGateNonConsoleRouteWhenOff() async throws {
        UserDefaults.standard.set(false, forKey: "requireAuthorizationForAllCommands")
        let spy = AuthorizationRequestSpy()
        let executor = LocalCommandExecutor(actionExecutor: NoopActionExecutor(), authorizer: spy)
        let command = makeConsoleCommand(action: .fishSettings)

        _ = await executor.execute(command, skipAuthorization: false)

        XCTAssertEqual(spy.requestCount, 0)
    }

    func testRequiresAuthorizationExemptsOnlyEmergencyStop() {
        UserDefaults.standard.set(true, forKey: "requireAuthorizationForAllCommands")
        let stop = makeConsoleCommand(action: .fishOff)
        let settings = makeConsoleCommand(action: .fishSettings)

        XCTAssertFalse(AuthorizationManager.shared.requiresAuthorization(stop))
        XCTAssertTrue(AuthorizationManager.shared.requiresAuthorization(settings))
    }

    // MARK: - X02-F04: Run Command honors enableBuiltInCommands

    func testIntentRunnerRejectsBuiltInWhenFlagOff() async throws {
        UserDefaults.standard.set(false, forKey: "enableBuiltInCommands")
        let container = try makeContainer()
        let context = ModelContext(container)
        let builtIn = Command(
            name: "Stop Listening",
            triggerPhrases: ["off"],
            actions: [CommandAction(type: .appIntent, payload: ConsoleAction.fishOff.rawValue, order: 0)],
            executionMode: .appIntents,
            catalogVersion: "built-in"
        )
        context.insert(builtIn)
        try context.save()

        do {
            _ = try await ExecuteCommandIntentRunner.execute(
                commandName: "Stop Listening",
                container: container,
                executor: CommandRunningCounterSpy()
            )
            XCTFail("Built-in must be rejected when enableBuiltInCommands is off")
        } catch let error as IntentError {
            XCTAssertEqual(error.localizedDescription, IntentError.commandNotFound("Stop Listening").localizedDescription)
        }
    }

    func testIntentRunnerRunsBuiltInWhenFlagOn() async throws {
        UserDefaults.standard.set(true, forKey: "enableBuiltInCommands")
        let container = try makeContainer()
        let context = ModelContext(container)
        let builtIn = Command(
            name: "Stop Listening",
            triggerPhrases: ["off"],
            actions: [CommandAction(type: .appIntent, payload: ConsoleAction.fishOff.rawValue, order: 0)],
            executionMode: .appIntents,
            catalogVersion: "built-in"
        )
        context.insert(builtIn)
        try context.save()

        let spy = CommandRunningCounterSpy()
        _ = try await ExecuteCommandIntentRunner.execute(
            commandName: "Stop Listening",
            container: container,
            executor: spy
        )
        XCTAssertEqual(spy.executedNames, ["Stop Listening"])
    }

    // MARK: - H05-F01: registry twins honor the disabled SwiftData starter

    func testDisabledConsoleStarterDisablesRegistryCommand() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(makeConsoleCommand(name: "Stop Listening", action: .fishOff, isEnabled: false))
        try context.save()

        let viewModel = MenuBarViewModel()
        viewModel.modelContext = context

        let registryCommand = ConsoleCommandRegistry.find(by: "stop-listening")
        XCTAssertNotNil(registryCommand)
        XCTAssertTrue(viewModel.isConsoleCommandDisabled(registryCommand!))
        XCTAssertTrue(viewModel.disabledConsoleActionPayloads().contains(ConsoleAction.fishOff.rawValue))
    }

    func testEnabledConsoleStarterKeepsRegistryCommandEnabled() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(makeConsoleCommand(name: "Stop Listening", action: .fishOff, isEnabled: true))
        try context.save()

        let viewModel = MenuBarViewModel()
        viewModel.modelContext = context

        XCTAssertFalse(viewModel.isConsoleCommandDisabled(ConsoleCommandRegistry.find(by: "stop-listening")!))
    }

    // MARK: - H05-F03: alias lists agree

    func testRegistryMakeNoiseAliasesMatchStarterList() {
        let registry = ConsoleCommandRegistry.find(by: "make-noise")
        XCTAssertNotNil(registry)
        XCTAssertTrue(registry!.triggerPhrases.contains("wake up"), "Registry must accept the starter alias 'wake up'")
        XCTAssertFalse(registry!.triggerPhrases.contains("make up"), "Registry must not carry the divergent alias 'make up'")
    }

    func testRegistryActionMappingCoversPrimaryCommands() {
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "stop-listening"), .fishOff)
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "show-settings"), .fishSettings)
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "show-recent-commands"), .showRecentCommands)
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "be-quiet"), .fishBeQuiet)
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "make-noise"), .fishMakeNoise)
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "new-command"), .newCommand)
        XCTAssertEqual(ConsoleCommandRegistry.consoleAction(for: "take-note"), .fishNote)
        XCTAssertNil(ConsoleCommandRegistry.consoleAction(for: "note-copy"))
    }

    // MARK: - Helpers

    private func makeConsoleCommand(
        name: String = "Settings",
        action: ConsoleAction,
        isEnabled: Bool = true
    ) -> Command {
        Command(
            name: name,
            triggerPhrases: ["synthetic console phrase"],
            actions: [CommandAction(type: .appIntent, payload: action.rawValue, order: 0)],
            executionMode: .appIntents,
            catalogVersion: "built-in",
            isEnabled: isEnabled,
            isConsole: true
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Command.self])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}

@MainActor
private final class AuthorizationRequestSpy: CommandAuthorizing {
    private(set) var requestCount = 0
    func requestAuthorization(for command: Command) async -> Bool {
        requestCount += 1
        return true
    }
}

private final class NoopActionExecutor: CommandActionExecuting {
    func execute(_ action: CommandAction) async throws -> String {
        "ok"
    }
}

private final class CommandRunningCounterSpy: CommandRunning {
    var isExecuting = false
    private(set) var executedNames: [String] = []

    func execute(_ command: Command, skipAuthorization: Bool) async -> CommandRun {
        executedNames.append(command.name)
        return CommandRun(
            id: UUID(),
            result: ExecutionResult(command: command, logs: [], overallSuccess: true, totalDurationMs: 0)
        )
    }

    func cancelExecution() {}
}