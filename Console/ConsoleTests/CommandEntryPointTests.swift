import XCTest
import SwiftData
@testable import Console

@MainActor
final class CommandEntryPointTests: XCTestCase {

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

    func testCommandListTestUsesInjectedExecutor() async {
        let spy = CommandRunningSpy()
        let command = makeSafeCommand(name: "Synthetic List Test")

        let run = await CommandListTesting.test(command, using: spy)

        XCTAssertEqual(spy.executedCommands.map(\.name), ["Synthetic List Test"])
        XCTAssertEqual(spy.skipAuthorizationFlags, [false])
        XCTAssertEqual(run.result.command.name, "Synthetic List Test")
        XCTAssertTrue(run.result.overallSuccess)
    }

    func testCommandCreationTestUsesInjectedExecutor() async {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(makeSafeCommand(name: "Synthetic Creation Test"))
        let spy = CommandRunningSpy()

        let run = await viewModel.testDraft(using: spy)

        XCTAssertEqual(spy.executedCommands.map(\.name), ["Synthetic Creation Test"])
        XCTAssertEqual(spy.skipAuthorizationFlags, [false])
        XCTAssertEqual(run?.result.command.name, "Synthetic Creation Test")
        XCTAssertTrue(viewModel.isCurrentDraftAuthorized)
    }

    func testCommandCreationTestPassesSkipAuthorization() async {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Creation Skip",
                payload: Self.dangerousAppleScriptFixture,
                requiresConfirmation: true
            )
        )
        viewModel.rememberDraftAuthorization()
        let spy = CommandRunningSpy()

        _ = await viewModel.testDraft(using: spy)

        XCTAssertEqual(spy.skipAuthorizationFlags, [true])
    }

    func testCommandCreationBusyResultDoesNotRememberAuthorization() async {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(makeSafeCommand(name: "Synthetic Creation Busy"))
        let spy = CommandRunningSpy()
        spy.resultProvider = { command, _ in CommandRun.alreadyRunning(command: command) }

        let run = await viewModel.testDraft(using: spy)

        XCTAssertTrue(run?.result.alreadyRunning == true)
        XCTAssertFalse(viewModel.isCurrentDraftAuthorized)
        XCTAssertEqual(spy.executedCommands.count, 1)
    }

    func testRecentCommandRunUsesInjectedExecutor() async {
        let spy = CommandRunningSpy()
        let controller = RecentCommandsController(executor: spy)
        let command = makeSafeCommand(name: "Synthetic Recent Run")

        let run = await controller.run(command)

        XCTAssertEqual(spy.executedCommands.map(\.name), ["Synthetic Recent Run"])
        XCTAssertEqual(run?.result.command.name, "Synthetic Recent Run")
    }

    func testAppIntentUsesInjectedExecutor() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let command = makeSafeCommand(name: "Synthetic Intent Run")
        context.insert(command)
        try context.save()

        let spy = CommandRunningSpy()
        let run = try await ExecuteCommandIntentRunner.execute(
            commandName: "Synthetic Intent Run",
            container: container,
            executor: spy
        )

        XCTAssertEqual(spy.executedCommands.map(\.name), ["Synthetic Intent Run"])
        XCTAssertEqual(run.result.command.name, "Synthetic Intent Run")
        XCTAssertEqual(
            ExecuteCommandIntentRunner.statusMessage(for: CommandRun.alreadyRunning(command: command)),
            CommandRun.alreadyRunningMessage
        )
    }

    func testVoiceUsesInjectedExecutor() async {
        let spy = CommandRunningSpy()
        let viewModel = MenuBarViewModel()
        viewModel.setListeningServices(
            localCommandExecutor: spy,
            aiProviderManager: AIProviderManager()
        )
        let command = makeSafeCommand(name: "Synthetic Voice Run")

        let run = await viewModel.executeLocalCommand(command)

        XCTAssertEqual(spy.executedCommands.map(\.name), ["Synthetic Voice Run"])
        XCTAssertTrue(run.result.overallSuccess)
    }

    func testGlobalStopCancelsInjectedExecutor() async {
        let spy = CommandRunningSpy()
        let viewModel = MenuBarViewModel()
        viewModel.setListeningServices(
            localCommandExecutor: spy,
            aiProviderManager: AIProviderManager()
        )

        NotificationCenter.default.post(name: .stopExecutionRequested, object: nil)
        await waitUntil { spy.cancelCount == 1 }

        XCTAssertEqual(spy.cancelCount, 1)
    }

    func testListLaunchSharesOwnerWithStop() async {
        let spy = CommandRunningSpy()
        let command = makeSafeCommand(name: "Synthetic Shared Owner")

        _ = await CommandListTesting.test(command, using: spy)
        spy.cancelExecution()

        XCTAssertEqual(spy.executedCommands.map(\.name), ["Synthetic Shared Owner"])
        XCTAssertEqual(spy.cancelCount, 1)
    }

    // MARK: - Helpers

    private func makeViewModel() -> CommandCreationViewModel {
        let schema = Schema([Command.self])
        let container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return CommandCreationViewModel(
            aiProviderManager: AIProviderManager(),
            modelContext: ModelContext(container)
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Command.self])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeSafeCommand(name: String) -> Command {
        Command(
            name: name,
            triggerPhrases: ["synthetic entry point"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: Self.safeAppleScriptFixture,
                    order: 0,
                    delayAfterMS: 0
                )
            ],
            executionMode: .appleScript,
            requiresConfirmation: false
        )
    }

    private func makeAppleScriptCommand(
        name: String,
        payload: String,
        requiresConfirmation: Bool
    ) -> Command {
        Command(
            name: name,
            triggerPhrases: ["synthetic entry point"],
            actions: [
                CommandAction(type: .appleScript, payload: payload, order: 0, delayAfterMS: 0)
            ],
            executionMode: .appleScript,
            requiresConfirmation: requiresConfirmation
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static let safeAppleScriptFixture = "return \"ok\""

    private static let dangerousAppleScriptFixture = """
    -- synthetic fixture: rm -rf
    return "ok"
    """
}

// MARK: - H19-F04: a cancelled capture whose mode was released ends listening

@MainActor
final class MenuBarCancelStateTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        AudioSessionController._unitTestMode = true
        await AudioSessionController.shared.shutdown()
    }

    @MainActor
    override func tearDown() async throws {
        await AudioSessionController.shared.shutdown()
        AudioSessionController._unitTestMode = false
    }

    @MainActor
    func testCancelWhileModeStillActiveReturnsToPassive() async {
        let viewModel = MenuBarViewModel()
        let mode = CommandListeningMode(transcriptSource: SyntheticTranscriptSource([]))
        await AudioSessionController.shared.requestMode(mode)
        viewModel.listeningState = .commandListening

        viewModel.handleCommandCancelled(from: mode)

        XCTAssertEqual(viewModel.listeningState, .passive)
        await AudioSessionController.shared.releaseMode(mode)
    }

    @MainActor
    func testCancelAfterModeWasReleasedEndsListening() async {
        let viewModel = MenuBarViewModel()
        let mode = CommandListeningMode(transcriptSource: SyntheticTranscriptSource([]))
        await AudioSessionController.shared.requestMode(mode)
        await AudioSessionController.shared.releaseMode(mode)
        viewModel.listeningState = .commandListening

        viewModel.handleCommandCancelled(from: mode)

        XCTAssertEqual(viewModel.listeningState, .off)
        XCTAssertEqual(viewModel.lastDetectedTrigger, "")
    }

    @MainActor
    func testCancelIsIgnoredWhenAlreadyOff() async {
        let viewModel = MenuBarViewModel()
        viewModel.listeningState = .off

        viewModel.handleCommandCancelled()

        XCTAssertEqual(viewModel.listeningState, .off)
    }
}

// MARK: - H23-F03: App Intent reports authorization denial truthfully

@MainActor
final class IntentStatusMessageTests: XCTestCase {

    private func makeRun(denied: Bool, success: Bool = false) -> CommandRun {
        let command = Command(
            name: "Synthetic Intent Deny",
            triggerPhrases: ["synthetic intent deny"],
            actions: [],
            executionMode: .appleScript
        )
        return CommandRun(
            id: UUID(),
            result: ExecutionResult(
                command: command,
                logs: [],
                overallSuccess: success,
                totalDurationMs: 0,
                authorizationDenied: denied
            )
        )
    }

    func testDeniedRunReportsAuthorizationDenied() {
        let message = ExecuteCommandIntentRunner.statusMessage(for: makeRun(denied: true))
        XCTAssertTrue(message.contains("Authorization denied"), "Got: \(message)")
        XCTAssertFalse(message.contains("Ran "), "Denial must not read as a generic run result: \(message)")
    }

    func testFailedRunStillReportsFailed() {
        let message = ExecuteCommandIntentRunner.statusMessage(for: makeRun(denied: false))
        XCTAssertEqual(message, "Ran \"Synthetic Intent Deny\": failed.")
    }
}

@MainActor
private final class CommandRunningSpy: CommandRunning {
    var isExecuting = false
    private(set) var executedCommands: [Command] = []
    private(set) var skipAuthorizationFlags: [Bool] = []
    private(set) var cancelCount = 0
    var resultProvider: ((Command, Bool) -> CommandRun)?

    func execute(_ command: Command, skipAuthorization: Bool) async -> CommandRun {
        executedCommands.append(command)
        skipAuthorizationFlags.append(skipAuthorization)
        return resultProvider?(command, skipAuthorization) ?? CommandRun(
            id: UUID(),
            result: ExecutionResult(
                command: command,
                logs: [],
                overallSuccess: true,
                totalDurationMs: 0
            )
        )
    }

    func cancelExecution() {
        cancelCount += 1
    }
}
