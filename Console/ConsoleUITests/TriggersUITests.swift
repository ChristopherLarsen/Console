import XCTest

final class TriggersUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Wake Word List

    func testWakeWordList() throws {
        // This test requires resetting wake word state to defaults, which persists across runs
        throw XCTSkip("Requires launch argument to reset wake words to defaults (e.g., --reset-wake-words)")
    }

    // MARK: - Add Wake Word

    func testAddWakeWord() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let triggersTab = app.buttons["Triggers"].firstMatch
        XCTAssertTrue(triggersTab.waitForExistence(timeout: 5))
        triggersTab.tap()

        let sectionHeader = app.staticTexts["Trigger Words"]
        XCTAssertTrue(sectionHeader.waitForExistence(timeout: 5))

        let addButton = app.buttons["addTriggerWordButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3), "Add button should be visible")
        addButton.tap()

        let sheetTitle = app.staticTexts["Add Trigger Word"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Add sheet should appear")

        let textField = app.textFields["Enter a trigger word"]
        XCTAssertTrue(textField.waitForExistence(timeout: 3), "Text field should be visible")
        textField.tap()
        textField.typeText("Hello")

        sleep(1)

        let sheetButtons = app.sheets.buttons["Add"]
        if sheetButtons.exists {
            sheetButtons.tap()
        } else {
            app.buttons["Add"].tap()
        }

        let newWord = app.staticTexts["Hello"]
        XCTAssertTrue(newWord.waitForExistence(timeout: 5), "New wake word 'Hello' should appear in list")
    }

    // MARK: - Add Duplicate Wake Word

    func testAddDuplicateWakeWord() throws {
        // This test requires resetting wake word state to defaults
        throw XCTSkip("Requires launch argument to reset wake words to defaults (e.g., --reset-wake-words)")
    }

    // MARK: - Toggle Wake Word

    func testToggleWakeWord() throws {
        // This test requires resetting wake word state to defaults
        throw XCTSkip("Requires launch argument to reset wake words to defaults (e.g., --reset-wake-words)")
    }

    // MARK: - Delete Last Wake Word

    func testDeleteLastWakeWord() throws {
        // This test requires resetting wake word state to defaults
        throw XCTSkip("Requires launch argument to reset wake words to defaults (e.g., --reset-wake-words)")
    }

    // MARK: - Delete Wake Word

    func testDeleteWakeWord() throws {
        // This test requires resetting wake word state to defaults
        throw XCTSkip("Requires launch argument to reset wake words to defaults (e.g., --reset-wake-words)")
    }

    // MARK: - Disable Last Wake Word

    func testDisableLastWakeWord() throws {
        // This test requires resetting wake word state to defaults
        throw XCTSkip("Requires launch argument to reset wake words to defaults (e.g., --reset-wake-words)")
    }
}
