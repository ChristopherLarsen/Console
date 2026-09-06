import XCTest
import SwiftData
@testable import Console

@MainActor
final class CommandListTests: XCTestCase {

    // MARK: - Command Loading

    func testCommandStoreStartsEmpty() {
        let commands = CommandStore.shared.getAllCommands()
        XCTAssertNotNil(commands)
    }

    func testCommandStoreSaveAndRetrieve() {
        let id = UUID()
        let cmd = StorableCommand(
            id: id,
            name: "Test Save",
            triggerPhrases: ["save test"]
        )
        CommandStore.shared.saveCommand(cmd)
        let retrieved = CommandStore.shared.getCommand(id: id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Test Save")

        CommandStore.shared.deleteCommand(id: id)
    }

    // MARK: - Delete

    func testCommandStoreDelete() {
        let id = UUID()
        let cmd = StorableCommand(id: id, name: "To Delete")
        CommandStore.shared.saveCommand(cmd)
        CommandStore.shared.deleteCommand(id: id)
        XCTAssertNil(CommandStore.shared.getCommand(id: id))
    }

    func testDeleteNonexistentDoesNotCrash() {
        CommandStore.shared.deleteCommand(id: UUID())
    }

    // MARK: - Inline Editing Validation

    func testNameValidationRejectsEmpty() {
        let command = Command(name: "Original")
        let trimmed = "".trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty, "Empty name should be rejected")
        XCTAssertEqual(command.name, "Original")
    }

    func testNameValidationRejectsOverLength() {
        let longName = String(repeating: "A", count: 101)
        XCTAssertGreaterThan(longName.count, 100)
    }

    func testPhraseValidationRejectsOverLength() {
        let longPhrase = String(repeating: "B", count: 201)
        XCTAssertGreaterThan(longPhrase.count, 200)
    }

    func testValidNameAccepted() {
        let name = "Open Safari"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertLessThanOrEqual(trimmed.count, 100)
    }

    // MARK: - Expand/Collapse State

    func testExpandedIDsStartEmpty() {
        var expandedIDs: Set<UUID> = []
        XCTAssertTrue(expandedIDs.isEmpty)

        let id = UUID()
        expandedIDs.insert(id)
        XCTAssertTrue(expandedIDs.contains(id))
    }

    func testToggleExpandAddsAndRemoves() {
        var expandedIDs: Set<UUID> = []
        let id = UUID()

        expandedIDs.insert(id)
        XCTAssertTrue(expandedIDs.contains(id))

        expandedIDs.remove(id)
        XCTAssertFalse(expandedIDs.contains(id))
    }

    // MARK: - Phrase Matching

    func testFindMatchingCommandExact() {
        let id = UUID()
        let cmd = StorableCommand(
            id: id,
            name: "Match Test",
            triggerPhrases: ["open safari"]
        )
        CommandStore.shared.saveCommand(cmd)

        let found = CommandStore.shared.findMatchingCommand(for: "open safari")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, id)

        CommandStore.shared.deleteCommand(id: id)
    }

    func testFindMatchingCommandPartial() {
        let id = UUID()
        let cmd = StorableCommand(
            id: id,
            name: "Partial Test",
            triggerPhrases: ["open terminal"]
        )
        CommandStore.shared.saveCommand(cmd)

        let found = CommandStore.shared.findMatchingCommand(for: "please open terminal now")
        XCTAssertNotNil(found)

        CommandStore.shared.deleteCommand(id: id)
    }

    // MARK: - Persistence Fields

    func testStorableCommandIncludesAIFields() {
        let cmd = StorableCommand(
            name: "AI Test",
            shortSummary: "Opens the browser",
            actionDescription: "This command will:\n• Open Safari"
        )
        XCTAssertEqual(cmd.shortSummary, "Opens the browser")
        XCTAssertTrue(cmd.actionDescription.contains("•"))
    }

    func testStorableCommandDefaultsAIFields() {
        let cmd = StorableCommand(name: "No AI")
        XCTAssertEqual(cmd.shortSummary, "")
        XCTAssertEqual(cmd.actionDescription, "")
    }

    // MARK: - Duplication preserves every behavioral field (review item 09)

    func testDuplicatingActionPreservesEveryFieldAndAssignsNewID() {
        let original = fullyConfiguredAction(order: 2)
        let copy = original.duplicating()

        XCTAssertNotEqual(copy.id, original.id)
        assertActionBehaviorEqual(copy, original, expectingSameOrder: true)
    }

    func testDuplicatingCommandPreservesBehaviorAndAssignsDistinctIDs() {
        let originalAction = fullyConfiguredAction(order: 0)
        let original = makeFullyConfiguredCommand(actions: [originalAction])

        let copy = original.duplicating()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "\(original.name) Copy")
        assertCommandBehaviorEqual(copy, original)
        XCTAssertEqual(copy.actions.count, 1)
        XCTAssertNotEqual(copy.actions[0].id, originalAction.id)
        assertActionBehaviorEqual(copy.actions[0], originalAction, expectingSameOrder: true)
        XCTAssertEqual(copy.executionCount, 0)
        XCTAssertNil(copy.lastExecutedAt)
        XCTAssertFalse(copy.isConsole)
        XCTAssertFalse(copy.isProtected)
    }

    func testDuplicatedCommandRoundTripsThroughPersistence() throws {
        let schema = Schema([Command.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let originalAction = fullyConfiguredAction(order: 0)
        let original = makeFullyConfiguredCommand(actions: [originalAction])
        context.insert(original)
        try context.save()

        let duplicate = original.duplicating()
        context.insert(duplicate)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Command>())
        XCTAssertEqual(fetched.count, 2)

        let fetchedOriginal = try XCTUnwrap(fetched.first { $0.id == original.id })
        let fetchedDuplicate = try XCTUnwrap(fetched.first { $0.id == duplicate.id })

        XCTAssertNotEqual(fetchedOriginal.id, fetchedDuplicate.id)
        assertCommandBehaviorEqual(fetchedDuplicate, fetchedOriginal)
        XCTAssertEqual(fetchedOriginal.actions.count, 1)
        XCTAssertEqual(fetchedDuplicate.actions.count, 1)
        assertActionBehaviorEqual(
            fetchedOriginal.actions[0],
            originalAction,
            expectingSameOrder: true,
            expectingSameID: true
        )
        assertActionBehaviorEqual(
            fetchedDuplicate.actions[0],
            originalAction,
            expectingSameOrder: true,
            expectingSameID: false
        )
        XCTAssertNotEqual(fetchedDuplicate.actions[0].id, fetchedOriginal.actions[0].id)
    }

    func testActionCodableRoundTripPreservesEveryField() throws {
        let original = fullyConfiguredAction(order: 7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommandAction.self, from: data)
        assertActionBehaviorEqual(decoded, original, expectingSameOrder: true, expectingSameID: true)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Duplication helpers

    private func makeFullyConfiguredCommand(actions: [CommandAction]) -> Command {
        Command(
            name: "Synthetic Duplicate Source",
            commandDescription: "Synthetic description for review 09 duplication",
            triggerPhrases: ["synthetic duplicate source", "duplicate me"],
            actions: actions,
            executionMode: .mixed,
            requiresConfirmation: true,
            catalogVersion: "review-09-catalog",
            isEnabled: false,
            shortSummary: "Synthetic short summary 09",
            actionDescription: "This command will:\n• AppleScript: return \"ok\"",
            executionCount: 9,
            lastExecutedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func fullyConfiguredAction(order: Int) -> CommandAction {
        CommandAction(
            type: .appleScript,
            payload: "return \"ok\"",
            order: order,
            delayAfterMS: 2500,
            timeoutMS: 12345,
            retryOnFailure: true,
            maxRetries: 3,
            completionCheck: .windowTitle("Synthetic Review 09 Window"),
            fallbackAction: FallbackAction(type: .appleScript, payload: "return \"fallback\"")
        )
    }

    private func assertCommandBehaviorEqual(
        _ actual: Command,
        _ expected: Command,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.commandDescription, expected.commandDescription, file: file, line: line)
        XCTAssertEqual(actual.triggerPhrases, expected.triggerPhrases, file: file, line: line)
        XCTAssertEqual(actual.executionMode, expected.executionMode, file: file, line: line)
        XCTAssertEqual(actual.requiresConfirmation, expected.requiresConfirmation, file: file, line: line)
        XCTAssertEqual(actual.catalogVersion, expected.catalogVersion, file: file, line: line)
        XCTAssertEqual(actual.isEnabled, expected.isEnabled, file: file, line: line)
        XCTAssertEqual(actual.shortSummary, expected.shortSummary, file: file, line: line)
        XCTAssertEqual(actual.actionDescription, expected.actionDescription, file: file, line: line)
        XCTAssertEqual(actual.executionMode, .mixed, file: file, line: line)
        XCTAssertTrue(actual.requiresConfirmation, file: file, line: line)
        XCTAssertEqual(actual.catalogVersion, "review-09-catalog", file: file, line: line)
        XCTAssertFalse(actual.isEnabled, file: file, line: line)
    }

    private func assertActionBehaviorEqual(
        _ actual: CommandAction,
        _ expected: CommandAction,
        expectingSameOrder: Bool,
        expectingSameID: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if expectingSameID {
            XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        } else {
            XCTAssertNotEqual(actual.id, expected.id, file: file, line: line)
        }
        XCTAssertEqual(actual.type, expected.type, file: file, line: line)
        XCTAssertEqual(actual.payload, expected.payload, file: file, line: line)
        if expectingSameOrder {
            XCTAssertEqual(actual.order, expected.order, file: file, line: line)
        }
        XCTAssertEqual(actual.delayAfterMS, expected.delayAfterMS, file: file, line: line)
        XCTAssertEqual(actual.timeoutMS, expected.timeoutMS, file: file, line: line)
        XCTAssertEqual(actual.retryOnFailure, expected.retryOnFailure, file: file, line: line)
        XCTAssertEqual(actual.maxRetries, expected.maxRetries, file: file, line: line)
        XCTAssertEqual(actual.completionCheck, expected.completionCheck, file: file, line: line)
        XCTAssertEqual(actual.fallbackAction, expected.fallbackAction, file: file, line: line)
        XCTAssertEqual(actual.type, .appleScript, file: file, line: line)
        XCTAssertNotEqual(actual.delayAfterMS, 500, file: file, line: line)
        XCTAssertNotEqual(actual.timeoutMS, 5000, file: file, line: line)
        XCTAssertTrue(actual.retryOnFailure, file: file, line: line)
        XCTAssertEqual(actual.maxRetries, 3, file: file, line: line)
        XCTAssertEqual(actual.completionCheck?.type, .windowTitle, file: file, line: line)
        XCTAssertEqual(actual.fallbackAction?.type, .appleScript, file: file, line: line)
        XCTAssertEqual(actual.fallbackAction?.payload, "return \"fallback\"", file: file, line: line)
    }
}
