import XCTest

/// Home Panel 2 (Sessions radar): default-launch panel presence, previewed
/// radar cards on Home, the Home → Sessions hop, and the creation-sheet entry
/// points. Launch arguments only — never launches Claude.
final class HomeSessionsUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Type-agnostic lookup: SwiftUI exposes custom cards as otherElements and
    /// controls as buttons, so match any element kind by identifier.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Default launch (Home)

    func testDefaultLaunchShowsHomePanelsWithEmptySessionsState() throws {
        app.launch()

        let sessionsPanel = element("HomePanelSessions")
        XCTAssertTrue(sessionsPanel.waitForExistence(timeout: 8), "Home shows the Sessions panel")

        let emptyState = element("HomePanelSessions.EmptyState")
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 8),
            "fresh launch shows the quiet empty state. Tree:\n\(app.debugDescription)"
        )

        // Sibling panels are untouched.
        XCTAssertTrue(element("HomePanelJiraTickets").exists, "JIRA panel still present")
        XCTAssertTrue(element("HomePanelGitLabMRsToReview").exists, "GitLab review placeholder still present")
        XCTAssertTrue(element("HomePanelGitLabMyMRs").exists, "GitLab authored placeholder still present")
    }

    // MARK: - Radar with injected sessions

    func testHomeSessionsPreviewListsCardsSortedByAttention() throws {
        app.launchArguments.append("-uiTestHomeSessionsPreview")
        app.launch()

        let alphaCard = element("HomeSessionCard.Preview Alpha")
        XCTAssertTrue(
            alphaCard.waitForExistence(timeout: 8),
            "radar shows Preview Alpha on Home. Tree:\n\(app.debugDescription)"
        )

        let betaCard = element("HomeSessionCard.Preview Beta")
        XCTAssertTrue(betaCard.exists, "radar shows Preview Beta on Home")

        XCTAssertLessThan(
            alphaCard.frame.minY,
            betaCard.frame.minY,
            "working session sorts above exited session"
        )
    }

    func testTappingRadarCardNavigatesToSessionsDestination() throws {
        app.launchArguments.append("-uiTestHomeSessionsPreview")
        app.launch()

        let alphaCard = element("HomeSessionCard.Preview Alpha")
        XCTAssertTrue(alphaCard.waitForExistence(timeout: 8))
        alphaCard.tap()

        let alphaRow = element("SessionRow.Preview Alpha")
        XCTAssertTrue(
            alphaRow.waitForExistence(timeout: 8),
            "jump lands on the Sessions destination with Alpha listed. Tree:\n\(app.debugDescription)"
        )
        let header = element("Sessions.Header")
        XCTAssertTrue(header.waitForExistence(timeout: 8), "selected terminal header present")
    }

    // MARK: - Header actions from an empty Home

    func testOpenSessionsFromEmptyHomeNavigatesWithoutSelecting() throws {
        app.launch()

        let openButton = element("HomePanelSessions.OpenSessionsButton")
        XCTAssertTrue(openButton.waitForExistence(timeout: 8))
        openButton.tap()

        let sessionsEmptyState = element("Sessions.EmptyState")
        XCTAssertTrue(
            sessionsEmptyState.waitForExistence(timeout: 8),
            "Open Sessions lands on the empty Sessions destination"
        )
    }

    func testNewSessionSheetOpensAndCancelReturnsToHomeEmptyState() throws {
        app.launch()

        let newButton = element("HomePanelSessions.NewSessionButton")
        XCTAssertTrue(newButton.waitForExistence(timeout: 8))
        newButton.tap()

        let nameField = element("SessionNameField")
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "creation sheet appears from Home")

        element("CancelSessionButton").tap()

        let emptyState = element("HomePanelSessions.EmptyState")
        XCTAssertTrue(emptyState.waitForExistence(timeout: 8), "cancel keeps zero sessions on Home")
    }
}
