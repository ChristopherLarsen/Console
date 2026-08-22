import XCTest

/// Sessions destination flows: zero-state, creation sheet, previewed rows,
/// switching, stop confirmation, exited retention, and pane ordering
/// (terminal on the left, session list on the right).
final class SessionsUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Type-agnostic lookup: SwiftUI exposes custom rows as otherElements and
    /// controls as buttons, so match any element kind by identifier.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launchSessions(preview: Bool) {
        if preview {
            app.launchArguments.append("-uiTestSessionsPreview")
        } else {
            app.launchArguments.append("-uiTestSelectSessions")
        }
        app.launch()
        let sessionsItem = element("Sessions")
        XCTAssertTrue(sessionsItem.waitForExistence(timeout: 5), "Sessions sidebar item should be visible")
        if !preview {
            // Exercise the real sidebar navigation path for the zero-state test.
            sessionsItem.tap()
        }
    }

    // MARK: - Zero-session UI

    func testZeroSessionStateShowsEmptyStateAndCreationEntry() throws {
        launchSessions(preview: false)

        let emptyState = element("Sessions.EmptyState")
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 8),
            "fresh install must show zero sessions. Tree:\n\(app.debugDescription)"
        )
    }

    // MARK: - Creation sheet

    func testCreationSheetOpensAndCancels() throws {
        launchSessions(preview: false)

        let newButton = element("NewSessionButton")
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        let nameField = element("SessionNameField")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "sheet shows an editable session name")

        let createButton = element("CreateSessionButton")
        XCTAssertFalse(createButton.isEnabled, "create stays disabled until a working directory is chosen")

        element("CancelSessionButton").tap()

        XCTAssertTrue(
            element("Sessions.EmptyState").waitForExistence(timeout: 5),
            "cancelling keeps zero sessions"
        )
    }

    // MARK: - Previewed rows (two concurrent sessions, switching, retention)

    func testTwoConcurrentSessionsListSwitchingAndExitedRetention() throws {
        launchSessions(preview: true)

        let alphaRow = element("SessionRow.Preview Alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5), "first concurrent session row visible")

        let betaRow = element("SessionRow.Preview Beta")
        XCTAssertTrue(betaRow.exists, "second concurrent session row visible")

        // Alpha is selected by the preview injection; its pane header is shown.
        let header = element("Sessions.Header")
        XCTAssertTrue(
            header.waitForExistence(timeout: 8),
            "selected terminal header present. Tree:\n\(app.debugDescription)"
        )

        // Switch to Beta.
        betaRow.tap()
        XCTAssertTrue(alphaRow.exists, "switching keeps both rows alive")

        // Exited session retains its row until removed.
        let removeButton = element("RemoveSessionButton.Preview Beta")
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "exited sessions expose removal")

        // Stop confirmation appears for a Working session.
        alphaRow.tap()
        let stopButton = element("StopSessionButton")
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.tap()

        let confirmStop = element("Sessions.ConfirmStopButton")
        XCTAssertTrue(
            confirmStop.waitForExistence(timeout: 8),
            "working sessions require stop confirmation. Tree:\n\(app.debugDescription)"
        )
        confirmStop.tap()
    }

    // MARK: - Pane ordering

    func testTerminalPaneSitsLeftOfSessionList() throws {
        launchSessions(preview: true)

        let header = element("Sessions.Header")
        XCTAssertTrue(
            header.waitForExistence(timeout: 8),
            "selected terminal header present. Tree:\n\(app.debugDescription)"
        )

        let alphaRow = element("SessionRow.Preview Alpha")
        XCTAssertTrue(alphaRow.exists, "session list row visible")

        XCTAssertLessThan(
            header.frame.maxX,
            alphaRow.frame.minX,
            "terminal pane occupies the left side; the session list sits on the right"
        )
    }
}
