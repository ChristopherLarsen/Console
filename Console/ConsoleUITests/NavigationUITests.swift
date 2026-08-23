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
        XCTAssertTrue(app.buttons["JIRA"].firstMatch.exists, "JIRA sidebar item should be visible")
        XCTAssertTrue(app.buttons["GitLab"].firstMatch.exists, "GitLab sidebar item should be visible")
        XCTAssertTrue(app.buttons["Triggers"].firstMatch.exists, "Triggers sidebar item should be visible")
        XCTAssertTrue(app.buttons["Commands"].firstMatch.exists, "Commands sidebar item should be visible")
        XCTAssertTrue(app.buttons["Sessions"].firstMatch.exists, "Sessions sidebar item should be visible")
        XCTAssertTrue(app.buttons["Settings"].firstMatch.exists, "Settings sidebar item should be visible")

        // Carapace-only items should not appear
        XCTAssertFalse(app.buttons["Claw Chat"].exists)
        XCTAssertFalse(app.buttons["Claw Control"].exists)
    }

    func testLaunchStartsOnHome() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let homeDashboard = app.descendants(matching: .any)["HomeDashboard"].firstMatch
        XCTAssertTrue(homeDashboard.waitForExistence(timeout: 5), "App should start on Home without tapping sidebar")
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

        let urlsSection = app.staticTexts["URL's"].firstMatch
        XCTAssertTrue(urlsSection.waitForExistence(timeout: 5), "Settings should show URL's section")
    }

    func testMergeRequestsSidebarAndSettingsURLField() throws {
        // Synthesized clicks on custom sidebar rows race window settling under
        // automation (same pre-existing issue as the Sessions destination test),
        // so navigate via launch argument and assert the destination renders.
        app.launchArguments.append("-uiTestSelectGitLab")
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        XCTAssertTrue(app.buttons["GitLab"].firstMatch.exists, "GitLab sidebar item should be visible")

        let legacyEmptyState = app.staticTexts["Set Web View Merge Requests URL in Settings"].firstMatch
        let reviewsEmptyState = app.staticTexts["Set Web View GitLab Reviews URL in Settings"].firstMatch
        let authoredEmptyState = app.staticTexts["Set Web View GitLab My MRs URL in Settings"].firstMatch
        let anySurface = app.descendants(matching: .any).matching(identifier: "MergeRequestsEmptyState").firstMatch
        let anyWebView = app.descendants(matching: .any).matching(identifier: "MergeRequestsWebView").firstMatch
        XCTAssertTrue(
            legacyEmptyState.waitForExistence(timeout: 2)
                || reviewsEmptyState.exists
                || authoredEmptyState.exists
                || anyWebView.exists
                || anySurface.exists,
            "GitLab destination should show empty state or web view"
        )

        let settingsItem = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), "Settings sidebar item should be visible")
        settingsItem.tap()

        let mergeRequestsURLLabel = app.staticTexts["Web View Merge Requests URL"].firstMatch
        XCTAssertTrue(mergeRequestsURLLabel.waitForExistence(timeout: 5), "Settings should show Web View Merge Requests URL field")

        // New GitLab list fields share the URL's section.
        let gitLabReviewsURLLabel = app.staticTexts["Web View GitLab Reviews URL"].firstMatch
        XCTAssertTrue(gitLabReviewsURLLabel.waitForExistence(timeout: 5), "Settings should show Web View GitLab Reviews URL field")

        let gitLabMyMRsURLLabel = app.staticTexts["Web View GitLab My MRs URL"].firstMatch
        XCTAssertTrue(gitLabMyMRsURLLabel.waitForExistence(timeout: 5), "Settings should show Web View GitLab My MRs URL field")
    }

    // MARK: - Home Panel 3 (GitLab MRs to Review)

    func testHomePanelThreeIsNotPlaceholder() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let homeDashboard = app.descendants(matching: .any)["HomeDashboard"].firstMatch
        XCTAssertTrue(homeDashboard.waitForExistence(timeout: 5), "App should start on Home")

        let reviewsPanel = app.descendants(matching: .any)["HomePanelGitLabMRsToReview"].firstMatch
        XCTAssertTrue(reviewsPanel.waitForExistence(timeout: 5), "Panel 3 container should be present")

        // The GitLab panel body replaces the placeholder: its own chrome is
        // rendered instead of the "Panel 3" placeholder copy.
        XCTAssertFalse(
            reviewsPanel.staticTexts["Panel 3"].exists,
            "Panel 3 should no longer render the placeholder body"
        )
        XCTAssertTrue(
            reviewsPanel.buttons["GitLabPanelRefreshButton"].waitForExistence(timeout: 5),
            "Panel 3 should expose its Refresh control"
        )
        XCTAssertTrue(
            reviewsPanel.buttons["GitLabPanelShowGitLabButton"].exists || reviewsPanel.otherElements["GitLabPanelUnconfiguredState"].exists,
            "Panel 3 should be interactive or explain an unconfigured URL"
        )
    }

    // MARK: - Home Panel 4 (GitLab My MRs)

    func testHomePanelFourIsNotPlaceholder() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let homeDashboard = app.descendants(matching: .any)["HomeDashboard"].firstMatch
        XCTAssertTrue(homeDashboard.waitForExistence(timeout: 5), "App should start on Home")

        let authoredPanel = app.descendants(matching: .any)["HomePanelGitLabMyMRs"].firstMatch
        XCTAssertTrue(authoredPanel.waitForExistence(timeout: 5), "Panel 4 container should be present")

        // The authored-MR panel body replaces the placeholder: its own chrome
        // is rendered instead of the "Panel 4" placeholder copy.
        XCTAssertFalse(
            authoredPanel.staticTexts["Panel 4"].exists,
            "Panel 4 should no longer render the placeholder body"
        )
        XCTAssertTrue(
            authoredPanel.buttons["GitLabPanelRefreshButton"].waitForExistence(timeout: 5),
            "Panel 4 should expose its Refresh control"
        )
        XCTAssertTrue(
            authoredPanel.buttons["GitLabPanelShowGitLabButton"].exists || authoredPanel.otherElements["GitLabPanelUnconfiguredState"].exists,
            "Panel 4 should be interactive or explain an unconfigured URL"
        )
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

    // MARK: - Sessions Destination

    func testSidebarSessionsShowsZeroSessionState() throws {
        // Synthesized clicks on custom sidebar rows race window settling under
        // automation (pre-existing: the JIRA content test shows the same), so
        // navigate via launch argument and assert the destination renders.
        app.launchArguments.append("-uiTestSelectSessions")
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")
        XCTAssertTrue(app.buttons["Sessions"].firstMatch.exists, "Sessions sidebar item should be visible")

        let emptyState = app.descendants(matching: .any).matching(identifier: "Sessions.EmptyState").firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5), "Sessions should start with zero sessions")
        XCTAssertTrue(app.buttons["NewSessionButton"].firstMatch.exists, "New session button should be available")
    }

    // MARK: - Bottom Terminal Drawer

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
