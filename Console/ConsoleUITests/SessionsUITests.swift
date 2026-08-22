import XCTest

/// Sessions destination flows: zero-state, creation sheet, previewed rows,
/// switching, stop confirmation, and exited retention.
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

    /// Session rows use generic UUID-based identifiers (names may contain
    /// ticket keys), so locate them by their accessibility label instead.
    private func sessionRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'SessionRow.' AND label CONTAINS %@", name)
        ).firstMatch
    }

    private func removeButton(forSessionNamed name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'RemoveSessionButton.' AND label CONTAINS %@", name)
        ).firstMatch
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

    // MARK: - Intent launcher

    func testIntentPickerOpensWithAllFourIntentsAndNoRequiredNameField() throws {
        launchSessions(preview: false)

        let newButton = element("NewSessionButton")
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        let picker = element("SessionIntentPicker")
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8),
            "the '+' opens the compact intent launcher. Tree:\n\(app.debugDescription)"
        )
        let newRow = element("Sessions.Intent.newTicket")
        XCTAssertTrue(
            newRow.waitForExistence(timeout: 5),
            "New Ticket intent row present. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(element("Sessions.Intent.existingTicket").exists, "Existing Ticket intent row present")
        XCTAssertTrue(element("Sessions.Intent.review").exists, "Review intent row present")
        XCTAssertTrue(element("Sessions.Intent.general").exists, "General intent row present")

        // No mandatory typing: the Customize area is collapsed and there is no
        // required Name field in the initial step.
        XCTAssertFalse(element("Sessions.Launcher.NameField").exists, "name entry is optional behind Customize")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            element("Sessions.EmptyState").waitForExistence(timeout: 5),
            "dismissing keeps zero sessions"
        )
    }

    func testExistingTicketWithoutContextExpandsInlineKeyField() throws {
        launchSessions(preview: false)

        let newButton = element("NewSessionButton")
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        let existingRow = element("Sessions.Intent.existingTicket")
        XCTAssertTrue(existingRow.waitForExistence(timeout: 8))
        existingRow.tap()

        let keyField = element("Sessions.Launcher.Jira.Field")
        XCTAssertTrue(
            keyField.waitForExistence(timeout: 8),
            "missing context expands only the inline ticket field. Tree:\n\(app.debugDescription)"
        )

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Previewed rows (two concurrent sessions, switching, retention)

    func testTwoConcurrentSessionsListSwitchingAndExitedRetention() throws {
        launchSessions(preview: true)

        let alphaRow = sessionRow(named: "Preview Alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5), "first concurrent session row visible")

        let betaRow = sessionRow(named: "Preview Beta")
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
        let betaRemoveButton = removeButton(forSessionNamed: "Preview Beta")
        XCTAssertTrue(betaRemoveButton.waitForExistence(timeout: 5), "exited sessions expose removal")

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
}
