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

    private func fetchSavedCommands() throws -> [Command] {
        try modelContext.fetch(FetchDescriptor<Command>())
    }

    /// Inert AppleScript. If executed it only returns a string.
    private static let safeAppleScriptFixture = "return \"ok\""

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
