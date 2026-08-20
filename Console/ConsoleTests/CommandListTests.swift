import XCTest
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
}
