import XCTest

final class CommandsUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Empty Command List

    func testEmptyCommandList() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let commandsTab = app.buttons["Commands"].firstMatch
        XCTAssertTrue(commandsTab.waitForExistence(timeout: 5))
        commandsTab.tap()

        // Verify that commands are displayed (either empty state or command list)
        let commandsTabLabel = app.staticTexts["Commands"]
        XCTAssertTrue(commandsTabLabel.waitForExistence(timeout: 3), "Commands view should be visible after tapping Commands tab")

        // Verify the add/create button is available
        let addButton = app.buttons["plus.circle.fill"]
        XCTAssertTrue(addButton.exists, "Create command button should be visible")
    }

    // MARK: - Command Creation

    func testCommandCreation() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let commandsTab = app.buttons["Commands"].firstMatch
        XCTAssertTrue(commandsTab.waitForExistence(timeout: 5))
        commandsTab.tap()

        let headerAddButton = app.buttons["plus.circle.fill"].firstMatch
        XCTAssertTrue(headerAddButton.waitForExistence(timeout: 5), "Add button should be visible")
        headerAddButton.tap()

        let sheetTitle = app.staticTexts["Create Command"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Creation sheet should appear")

        let phraseField = app.textFields["e.g. open music, play tunes"]
        XCTAssertTrue(phraseField.exists, "Command phrase text field should be visible")

        let descriptionLabel = app.staticTexts["Command Description"]
        XCTAssertTrue(descriptionLabel.exists, "Command Description label should be visible")
    }

    // MARK: - Command Creation No Provider

    func testCommandCreationNoProvider() throws {
        // This test requires clearing the AI provider configuration, which is not supported
        // via launch arguments. The app likely has a default provider set.
        throw XCTSkip("Requires AI provider state clearing - no launch argument available to disable providers")
    }

    // MARK: - Command List Sorting

    func testCommandListSorting() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Command Expansion

    func testCommandExpansion() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Command Detail

    func testCommandDetail() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Command Edit

    func testCommandEdit() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Command Delete

    func testCommandDelete() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Built-In Commands

    func testBuiltInCommands() throws {
        throw XCTSkip("TODO: Develop test")
    }
}
