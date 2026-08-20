import XCTest

final class NavigationUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Sidebar Navigation

    func testSidebarHasPrimaryItems() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 5), "Home sidebar item should be visible")
        XCTAssertTrue(app.buttons["Triggers"].firstMatch.exists, "Triggers sidebar item should be visible")
        XCTAssertTrue(app.buttons["Commands"].firstMatch.exists, "Commands sidebar item should be visible")
        XCTAssertTrue(app.buttons["JIRA"].firstMatch.exists, "JIRA sidebar item should be visible")
        XCTAssertTrue(app.buttons["Terminal"].firstMatch.exists, "Terminal sidebar item should be visible")
        XCTAssertTrue(app.buttons["Settings"].firstMatch.exists, "Settings sidebar item should be visible")

        // Carapace-only items should not appear
        XCTAssertFalse(app.buttons["Claw Chat"].exists)
        XCTAssertFalse(app.buttons["Claw Control"].exists)
    }

    func testLaunchStartsOnHome() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let homeTitle = app.staticTexts["Home"].firstMatch
        XCTAssertTrue(homeTitle.waitForExistence(timeout: 5), "App should start on Home without tapping sidebar")
    }

    func testJiraSidebarAndSettingsURLField() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let jiraItem = app.buttons["JIRA"].firstMatch
        XCTAssertTrue(jiraItem.waitForExistence(timeout: 5), "JIRA sidebar item should be visible")
        jiraItem.tap()

        // Empty URL shows empty state by default
        let emptyState = app.staticTexts["Set Web View JIRA URL in Settings"].firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 5) || app.otherElements["JiraWebView"].exists || app.otherElements["JiraEmptyState"].exists,
            "JIRA destination should show empty state or web view"
        )

        let settingsItem = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), "Settings sidebar item should be visible")
        settingsItem.tap()

        let jiraURLLabel = app.staticTexts["Web View JIRA URL"].firstMatch
        XCTAssertTrue(jiraURLLabel.waitForExistence(timeout: 5), "Settings should show Web View JIRA URL field")
    }

    func testSettingsSidebarShowsSettings() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let settingsItem = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), "Settings sidebar item should be visible")
        settingsItem.tap()

        // Inner segmented Settings tab should not be used for navigation
        let settingsSegment = app.radioButtons["Settings"]
        XCTAssertFalse(settingsSegment.exists, "Settings should not appear as a segmented tab")
    }

    func testTriggersAndCommandsSidebarNavigation() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let triggersItem = app.buttons["Triggers"].firstMatch
        XCTAssertTrue(triggersItem.waitForExistence(timeout: 5))
        triggersItem.tap()

        let commandsItem = app.buttons["Commands"].firstMatch
        XCTAssertTrue(commandsItem.exists)
        commandsItem.tap()
    }

    // MARK: - Terminal Panel

    func testSidebarTerminalTogglesPanelWithoutChangingCenter() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let homeItem = app.buttons["Home"].firstMatch
        XCTAssertTrue(homeItem.waitForExistence(timeout: 5))
        homeItem.tap()

        let homeTitle = app.staticTexts["Home"].firstMatch
        XCTAssertTrue(homeTitle.waitForExistence(timeout: 5), "Home center content should be visible")

        let collapseButton = app.buttons["ToggleTerminalCollapse"].firstMatch
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5), "Terminal chevron should be visible when expanded")

        let terminalSidebar = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(terminalSidebar.exists)
        terminalSidebar.tap()

        // Center page stays Home; Terminal row toggles the bottom panel only.
        XCTAssertTrue(homeTitle.exists, "Sidebar Terminal should not replace center content")
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5), "Collapsed Terminal bar should remain pinned")

        terminalSidebar.tap()
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5), "Terminal chevron should remain after expand")
        XCTAssertTrue(homeTitle.exists, "Center content should still be Home after expand")
    }

    func testTerminalChevronCollapsesAndExpands() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let collapseButton = app.buttons["ToggleTerminalCollapse"].firstMatch
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5), "Terminal chevron should be visible")

        let terminalTitle = app.staticTexts["Terminal"].firstMatch
        XCTAssertTrue(terminalTitle.exists, "Terminal title bar should be visible when expanded")

        collapseButton.tap()
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 5), "Terminal title bar should stay pinned when collapsed")
        XCTAssertTrue(collapseButton.exists, "Chevron should remain on the pinned bar")

        collapseButton.tap()
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5), "Chevron should still exist after expand")
        XCTAssertTrue(terminalTitle.exists, "Terminal title should remain visible when expanded")
    }

    // MARK: - Live Tab Visibility

    func testLiveTabHiddenByDefault() throws {
        app.launchArguments.append("-com.console.developerModeEnabled")
        app.launchArguments.append("0")
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let liveTab = app.buttons["Live"]
        XCTAssertFalse(liveTab.exists, "Live tab should be hidden when developer mode is off")
    }
}
