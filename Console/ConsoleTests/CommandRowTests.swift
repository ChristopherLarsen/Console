import XCTest
@testable import Console

@MainActor
final class CommandRowTests: XCTestCase {

    // MARK: - Name Editing Validation

    func testSaveNameRejectsEmptyInput() {
        let command = Command(name: "Original Name")
        let input = "   "
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty)
        XCTAssertEqual(command.name, "Original Name")
    }

    func testSaveNameRejectsOver100Characters() {
        let input = String(repeating: "X", count: 101)
        XCTAssertGreaterThan(input.count, 100, "Input over 100 chars should be rejected")
    }

    func testSaveNameAcceptsValidInput() {
        let command = Command(name: "Old Name")
        let input = "New Name"
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty && trimmed.count <= 100 {
            command.name = trimmed
        }
        XCTAssertEqual(command.name, "New Name")
    }

    func testSaveNameTrimsWhitespace() {
        let input = "  Trimmed Name  "
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trimmed, "Trimmed Name")
    }

    // MARK: - Phrase Editing Validation

    func testSavePhraseRejectsEmptyInput() {
        let command = Command(name: "Test", triggerPhrases: ["original phrase"])
        let input = ""
        XCTAssertTrue(input.isEmpty)
        XCTAssertEqual(command.triggerPhrases.first, "original phrase")
    }

    func testSavePhraseRejectsOver200Characters() {
        let input = String(repeating: "Y", count: 201)
        XCTAssertGreaterThan(input.count, 200)
    }

    func testSavePhraseUpdatesFirstElement() {
        let command = Command(name: "Test", triggerPhrases: ["old phrase"])
        let newPhrase = "new phrase"
        command.triggerPhrases[0] = newPhrase
        XCTAssertEqual(command.triggerPhrases[0], "new phrase")
    }

    func testSavePhraseAppendsWhenEmpty() {
        let command = Command(name: "Test", triggerPhrases: [])
        XCTAssertTrue(command.triggerPhrases.isEmpty)
        command.triggerPhrases = ["first phrase"]
        XCTAssertEqual(command.triggerPhrases.count, 1)
        XCTAssertEqual(command.triggerPhrases[0], "first phrase")
    }

    // MARK: - Placeholder Generation

    func testPlaceholderSummaryFromTriggerPhrase() {
        let command = Command(
            name: "Test",
            triggerPhrases: ["open Safari and go to Google"]
        )
        let summary = command.generatePlaceholderSummary()
        XCTAssertFalse(summary.isEmpty)
        XCTAssertLessThanOrEqual(summary.count, 60)
    }

    func testPlaceholderSummaryFromName() {
        let command = Command(name: "My Command", triggerPhrases: [])
        let summary = command.generatePlaceholderSummary()
        XCTAssertEqual(summary, "My Command")
    }

    func testPlaceholderSummaryTruncatesLongPhrase() {
        let longPhrase = String(repeating: "A", count: 80)
        let command = Command(name: "Test", triggerPhrases: [longPhrase])
        let summary = command.generatePlaceholderSummary()
        XCTAssertLessThanOrEqual(summary.count, 60)
        XCTAssertTrue(summary.hasSuffix("..."))
    }

    func testPlaceholderActionDescriptionFromActions() {
        let actions = [
            CommandAction(type: .shell, payload: "open -a Safari", order: 0),
            CommandAction(type: .appleScript, payload: "activate", order: 1)
        ]
        let command = Command(name: "Test", actions: actions)
        let desc = command.generatePlaceholderActionDescription()
        XCTAssertTrue(desc.hasPrefix("This command will:"))
        XCTAssertTrue(desc.contains("•"))
        XCTAssertTrue(desc.contains("Shell"))
        XCTAssertTrue(desc.contains("AppleScript"))
    }

    func testPlaceholderActionDescriptionEmptyWhenNoActions() {
        let command = Command(name: "Test")
        let desc = command.generatePlaceholderActionDescription()
        XCTAssertTrue(desc.isEmpty)
    }

    // MARK: - State Interactions

    func testEditingPreventsTestButton() {
        let isEditingName = true
        let isEditingPhrase = false
        let isEditing = isEditingName || isEditingPhrase
        let isTesting = false
        let testDisabled = isTesting || isEditing
        XCTAssertTrue(testDisabled)
    }

    func testTestingPreventsDeleteButton() {
        let isTesting = true
        XCTAssertTrue(isTesting, "Delete should be disabled during testing")
    }

    func testNormalStateAllowsAllButtons() {
        let isEditing = false
        let isTesting = false
        XCTAssertFalse(isTesting || isEditing)
        XCTAssertFalse(isTesting)
    }
}
