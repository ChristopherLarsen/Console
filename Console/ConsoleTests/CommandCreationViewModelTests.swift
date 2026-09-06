import XCTest
import SwiftData
@testable import Console

@MainActor
final class CommandCreationViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var modelContext: ModelContext!

    override func setUp() {
        super.setUp()
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        modelContext = ModelContext(container)
    }

    override func tearDown() {
        modelContext = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Save / Test flag preservation

    func testSaveRetainsGeneratedConfirmationFlag() throws {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Confirm Save",
                phrases: ["synthetic confirm save"],
                payload: Self.dangerousAppleScriptFixture,
                requiresConfirmation: true
            )
        )

        XCTAssertTrue(viewModel.editableRequiresConfirmation)
        XCTAssertTrue(viewModel.save())

        let saved = try fetchSavedCommands()
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].requiresConfirmation)
        XCTAssertEqual(saved[0].name, "Synthetic Confirm Save")
    }

    func testTestDraftRetainsGeneratedConfirmationFlag() {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Confirm Test",
                phrases: ["synthetic confirm test"],
                payload: Self.dangerousAppleScriptFixture,
                requiresConfirmation: true
            )
        )

        guard case let .ready(command, skipAuthorization) = viewModel.prepareDraftForExecution() else {
            return XCTFail("Expected a ready draft")
        }
        XCTAssertTrue(command.requiresConfirmation)
        XCTAssertFalse(skipAuthorization)
    }

    func testEditingInDangerousOperationSetsConfirmation() {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Edit Danger",
                phrases: ["synthetic edit danger"],
                payload: Self.safeAppleScriptFixture,
                requiresConfirmation: false
            )
        )
        XCTAssertFalse(viewModel.editableRequiresConfirmation)

        viewModel.updateActionPayload(at: 0, payload: Self.dangerousAppleScriptFixture)

        XCTAssertTrue(viewModel.editableRequiresConfirmation)
        guard case let .ready(command, _) = viewModel.prepareDraftForExecution() else {
            return XCTFail("Expected a ready draft after editing in danger")
        }
        XCTAssertTrue(command.requiresConfirmation)
        XCTAssertTrue(viewModel.save())
    }

    func testSafeCommandDoesNotGainConfirmation() throws {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Safe Save",
                phrases: ["synthetic safe save"],
                payload: Self.safeAppleScriptFixture,
                requiresConfirmation: false
            )
        )

        XCTAssertFalse(viewModel.editableRequiresConfirmation)
        XCTAssertTrue(viewModel.save())

        let saved = try fetchSavedCommands()
        XCTAssertEqual(saved.count, 1)
        XCTAssertFalse(saved[0].requiresConfirmation)

        guard case let .ready(command, skipAuthorization) = viewModel.prepareDraftForExecution() else {
            return XCTFail("Expected a ready safe draft")
        }
        XCTAssertFalse(command.requiresConfirmation)
        XCTAssertFalse(skipAuthorization)
    }

    // MARK: - Draft authorization

    func testUnchangedAuthorizedDraftSkipsSecondAuthorization() {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Auth Skip",
                phrases: ["synthetic auth skip"],
                payload: Self.dangerousAppleScriptFixture,
                requiresConfirmation: true
            )
        )

        guard case let .ready(_, firstSkip) = viewModel.prepareDraftForExecution() else {
            return XCTFail("Expected a ready draft")
        }
        XCTAssertFalse(firstSkip)

        viewModel.rememberDraftAuthorization()

        guard case let .ready(command, secondSkip) = viewModel.prepareDraftForExecution() else {
            return XCTFail("Expected a ready draft after authorization")
        }
        XCTAssertTrue(command.requiresConfirmation)
        XCTAssertTrue(secondSkip)
    }

    func testEditingAuthorizedDraftInvalidatesAuthorization() {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Auth Invalidate",
                phrases: ["synthetic auth invalidate"],
                payload: Self.dangerousAppleScriptFixture,
                requiresConfirmation: true
            )
        )
        viewModel.rememberDraftAuthorization()
        XCTAssertTrue(viewModel.isCurrentDraftAuthorized)

        viewModel.updateActionPayload(at: 0, payload: Self.alternateDangerousAppleScriptFixture)

        XCTAssertFalse(viewModel.isCurrentDraftAuthorized)
        XCTAssertTrue(viewModel.editableRequiresConfirmation)
        guard case let .ready(command, skipAuthorization) = viewModel.prepareDraftForExecution() else {
            return XCTFail("Expected a ready draft after invalidating authorization")
        }
        XCTAssertTrue(command.requiresConfirmation)
        XCTAssertFalse(skipAuthorization)
    }

    func testGeneratedConfirmationSurvivesWhenValidatorDoesNotFlagPayload() throws {
        let viewModel = makeViewModel()
        viewModel.presentGeneratedCommand(
            makeAppleScriptCommand(
                name: "Synthetic Marked Safe Payload",
                phrases: ["synthetic marked safe payload"],
                payload: Self.safeAppleScriptFixture,
                requiresConfirmation: true
            )
        )

        XCTAssertTrue(viewModel.editableRequiresConfirmation)
        XCTAssertTrue(viewModel.save())
        let saved = try fetchSavedCommands()
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].requiresConfirmation)
    }

    // MARK: - Action setting preservation (review item 09)

    func testUpdatingPayloadChangesOnlyPayload() {
        let viewModel = makeViewModel()
        let original = fullyConfiguredAction(
            payload: Self.safeAppleScriptFixture,
            order: 0
        )
        viewModel.presentGeneratedCommand(makeCommand(actions: [original]))

        viewModel.updateActionPayload(at: 0, payload: Self.alternateSafeAppleScriptFixture)

        XCTAssertEqual(viewModel.editableActions.count, 1)
        let updated = viewModel.editableActions[0]
        XCTAssertEqual(updated.payload, Self.alternateSafeAppleScriptFixture)
        assertActionSettingsEqual(updated, original, expectingSameID: true, ignoringPayload: true)
        XCTAssertNotEqual(updated.payload, original.payload)
    }

    func testRemovingActionReordersWithoutResettingSettings() {
        let viewModel = makeViewModel()
        let first = fullyConfiguredAction(
            payload: Self.safeAppleScriptFixture,
            order: 0,
            delayAfterMS: 2100,
            timeoutMS: 11111,
            maxRetries: 2,
            completionValue: "/tmp/console-review-09-first",
            fallbackPayload: "return \"first-fallback\""
        )
        let second = fullyConfiguredAction(
            payload: Self.alternateSafeAppleScriptFixture,
            order: 1,
            delayAfterMS: 3200,
            timeoutMS: 22222,
            maxRetries: 4,
            completionValue: "/tmp/console-review-09-second",
            fallbackPayload: "return \"second-fallback\""
        )
        viewModel.presentGeneratedCommand(makeCommand(actions: [first, second]))

        viewModel.removeAction(at: 0)

        XCTAssertEqual(viewModel.editableActions.count, 1)
        let remaining = viewModel.editableActions[0]
        XCTAssertEqual(remaining.order, 0)
        XCTAssertEqual(remaining.id, second.id)
        XCTAssertEqual(remaining.payload, second.payload)
        XCTAssertEqual(remaining.type, second.type)
        XCTAssertEqual(remaining.delayAfterMS, second.delayAfterMS)
        XCTAssertEqual(remaining.timeoutMS, second.timeoutMS)
        XCTAssertEqual(remaining.retryOnFailure, second.retryOnFailure)
        XCTAssertEqual(remaining.maxRetries, second.maxRetries)
        XCTAssertEqual(remaining.completionCheck, second.completionCheck)
        XCTAssertEqual(remaining.fallbackAction, second.fallbackAction)
    }

    func testSaveRoundTripsAllActionFields() throws {
        let viewModel = makeViewModel()
        let original = fullyConfiguredAction(
            payload: Self.safeAppleScriptFixture,
            order: 0
        )
        viewModel.presentGeneratedCommand(makeCommand(actions: [original]))

        XCTAssertTrue(viewModel.save())

        let saved = try fetchSavedCommands()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].actions.count, 1)
        assertActionSettingsEqual(saved[0].actions[0], original, expectingSameID: true)
    }

    // MARK: - Helpers

    private func makeViewModel() -> CommandCreationViewModel {
        CommandCreationViewModel(
            aiProviderManager: AIProviderManager(),
            modelContext: modelContext
        )
    }

    private func makeAppleScriptCommand(
        name: String,
        phrases: [String],
        payload: String,
        requiresConfirmation: Bool
    ) -> Command {
        Command(
            name: name,
            triggerPhrases: phrases,
            actions: [
                CommandAction(type: .appleScript, payload: payload, order: 0)
            ],
            executionMode: .appleScript,
            requiresConfirmation: requiresConfirmation
        )
    }

    private func makeCommand(actions: [CommandAction]) -> Command {
        Command(
            name: "Synthetic Full Action Settings",
            triggerPhrases: ["synthetic full action settings"],
            actions: actions,
            executionMode: .appleScript,
            requiresConfirmation: false
        )
    }

    private func fullyConfiguredAction(
        payload: String,
        order: Int,
        delayAfterMS: Int = 2500,
        timeoutMS: Int = 12345,
        maxRetries: Int? = 3,
        completionValue: String = "/tmp/console-review-09-check",
        fallbackPayload: String = "return \"fallback\""
    ) -> CommandAction {
        CommandAction(
            type: .appleScript,
            payload: payload,
            order: order,
            delayAfterMS: delayAfterMS,
            timeoutMS: timeoutMS,
            retryOnFailure: true,
            maxRetries: maxRetries,
            completionCheck: .fileExists(completionValue),
            fallbackAction: FallbackAction(type: .appleScript, payload: fallbackPayload)
        )
    }

    private func assertActionSettingsEqual(
        _ actual: CommandAction,
        _ expected: CommandAction,
        expectingSameID: Bool,
        ignoringPayload: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if expectingSameID {
            XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        } else {
            XCTAssertNotEqual(actual.id, expected.id, file: file, line: line)
        }
        XCTAssertEqual(actual.type, expected.type, file: file, line: line)
        if !ignoringPayload {
            XCTAssertEqual(actual.payload, expected.payload, file: file, line: line)
        }
        XCTAssertEqual(actual.order, expected.order, file: file, line: line)
        XCTAssertEqual(actual.delayAfterMS, expected.delayAfterMS, file: file, line: line)
        XCTAssertEqual(actual.timeoutMS, expected.timeoutMS, file: file, line: line)
        XCTAssertEqual(actual.retryOnFailure, expected.retryOnFailure, file: file, line: line)
        XCTAssertEqual(actual.maxRetries, expected.maxRetries, file: file, line: line)
        XCTAssertEqual(actual.completionCheck, expected.completionCheck, file: file, line: line)
        XCTAssertEqual(actual.fallbackAction, expected.fallbackAction, file: file, line: line)
        XCTAssertEqual(actual.completionCheck?.type, .fileExists, file: file, line: line)
        XCTAssertNotNil(actual.fallbackAction, file: file, line: line)
        XCTAssertNotEqual(actual.delayAfterMS, 500, file: file, line: line)
        XCTAssertNotEqual(actual.timeoutMS, 5000, file: file, line: line)
        XCTAssertTrue(actual.retryOnFailure, file: file, line: line)
        XCTAssertNotNil(actual.maxRetries, file: file, line: line)
    }

    private func fetchSavedCommands() throws -> [Command] {
        try modelContext.fetch(FetchDescriptor<Command>())
    }

    /// Inert AppleScript. If executed it only returns a string.
    private static let safeAppleScriptFixture = "return \"ok\""

    private static let alternateSafeAppleScriptFixture = "return \"ok-edited\""

    /// Inert AppleScript whose source contains a dangerous token so validation flags it.
    /// The token lives in a comment; the script only returns a string.
    private static let dangerousAppleScriptFixture = """
    -- synthetic fixture: rm -rf
    return "ok"
    """

    private static let alternateDangerousAppleScriptFixture = """
    -- synthetic fixture: sudo
    return "ok"
    """
}
