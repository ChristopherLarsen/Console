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

    private func toggleFocusSessionChrome() {
        app.activate()
        let focusMenu = app.menuItems["Focus Session"]
        if focusMenu.waitForExistence(timeout: 3) {
            focusMenu.click()
        } else {
            app.typeKey("f", modifierFlags: [.command, .shift])
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

    // MARK: - Synthetic launch failure

    func testSyntheticLaunchFailureShowsActionableError() throws {
        app.launchArguments.append("-uiTestSessionLaunchFailure")
        app.launch()

        let error = element("Sessions.Launch.Error")
        XCTAssertTrue(
            error.waitForExistence(timeout: 8),
            "contextual launch failure must be visible on Home. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            element("HomePanelSessions").waitForExistence(timeout: 5),
            "failed launches stay on Home instead of opening Sessions"
        )
        XCTAssertTrue(
            element("Sessions.Launch.OpenSettings").waitForExistence(timeout: 5),
            "executable/folder failures expose a Settings route"
        )
        let claudeText = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "Claude Code")
        ).firstMatch
        XCTAssertTrue(
            claudeText.exists,
            "missing-Claude copy must be visible. Tree:\n\(app.debugDescription)"
        )
        XCTAssertFalse(element("Sessions.Header").exists, "must not navigate as if the session started")
        XCTAssertFalse(element("Sessions.EmptyState").exists)
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

    // MARK: - Pane ordering

    func testTerminalPaneSitsLeftOfSessionList() throws {
        launchSessions(preview: true)

        let header = element("Sessions.Header")
        XCTAssertTrue(
            header.waitForExistence(timeout: 8),
            "selected terminal header present. Tree:\n\(app.debugDescription)"
        )

        let alphaRow = sessionRow(named: "Preview Alpha")
        XCTAssertTrue(alphaRow.exists, "session list row visible")

        XCTAssertLessThan(
            header.frame.maxX,
            alphaRow.frame.minX,
            "terminal pane occupies the left side; the session list sits on the right"
        )
    }

    // MARK: - Focus Session

    func testFocusSessionHidesListAndRestoresIt() throws {
        launchSessions(preview: true)

        let alphaRow = sessionRow(named: "Preview Alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5), "first concurrent session row visible")
        XCTAssertTrue(sessionRow(named: "Preview Beta").exists, "second concurrent session row visible")

        let header = element("Sessions.Header")
        XCTAssertTrue(header.waitForExistence(timeout: 8), "selected terminal header present")

        let list = element("Sessions.List")
        XCTAssertTrue(list.waitForExistence(timeout: 5), "session list is visible before focus")
        XCTAssertTrue(element("NewSessionButton").exists, "list chrome is present before focus")

        let terminalToggle = element("Terminal")
        XCTAssertTrue(terminalToggle.waitForExistence(timeout: 5), "Terminal sidebar item stays mounted")

        app.activate()
        toggleFocusSessionChrome()

        XCTAssertTrue(
            list.waitForNonExistence(timeout: 5),
            "focus mode unmounts the session list rather than hiding it. Tree:\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            sessionRow(named: "Preview Alpha").exists,
            "hidden list must not leave session rows in the accessibility tree"
        )
        XCTAssertFalse(
            sessionRow(named: "Preview Beta").exists,
            "hidden list must not leave duplicate session rows"
        )
        XCTAssertFalse(element("NewSessionButton").exists, "list header unmounts with the list")
        XCTAssertFalse(element("Sessions.ShowListButton").exists, "focus mode does not leave a list rail")
        XCTAssertTrue(element("Sessions.ToggleListButton").waitForExistence(timeout: 5), "toolbar toggle stays available in focus mode")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "selected session terminal remains")
        XCTAssertFalse(element("Sessions.FocusToggle").exists, "pane header no longer hosts a Focus Session button")
        XCTAssertTrue(terminalToggle.exists, "Terminal sidebar toggle stays mounted while the drawer is retracted")

        toggleFocusSessionChrome()

        let restoredList = element("Sessions.List")
        XCTAssertTrue(
            restoredList.waitForExistence(timeout: 5),
            "exiting focus restores the session list. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            sessionRow(named: "Preview Alpha").waitForExistence(timeout: 5),
            "Alpha row identity is restored"
        )
        XCTAssertTrue(
            sessionRow(named: "Preview Beta").waitForExistence(timeout: 5),
            "Beta row identity is restored"
        )
        XCTAssertTrue(element("NewSessionButton").waitForExistence(timeout: 5))
        XCTAssertTrue(header.exists, "selected terminal remains after restore")
        XCTAssertTrue(terminalToggle.exists, "Terminal sidebar toggle remains after restore")

        app.typeKey("2", modifierFlags: .command)
        toggleFocusSessionChrome()
        XCTAssertTrue(
            element("Sessions.List").waitForNonExistence(timeout: 5),
            "focus after switching still unmounts the list"
        )
        XCTAssertTrue(header.waitForExistence(timeout: 5), "switched session keeps its terminal pane")
        XCTAssertFalse(sessionRow(named: "Preview Alpha").exists)
        XCTAssertFalse(sessionRow(named: "Preview Beta").exists)

        toggleFocusSessionChrome()
        XCTAssertTrue(element("Sessions.List").waitForExistence(timeout: 5))
        XCTAssertTrue(sessionRow(named: "Preview Alpha").waitForExistence(timeout: 5))
        XCTAssertTrue(sessionRow(named: "Preview Beta").waitForExistence(timeout: 5))
    }

    // MARK: - Session list toolbar toggle

    func testToolbarToggleUnmountsAndRestoresSessionList() throws {
        launchSessions(preview: true)

        let alphaRow = sessionRow(named: "Preview Alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5), "session list visible before toggle")

        let toggle = element("Sessions.ToggleListButton")
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 5),
            "list toggle lives in the window toolbar. Tree:\n\(app.debugDescription)"
        )

        toggle.tap()
        XCTAssertTrue(
            alphaRow.waitForNonExistence(timeout: 5),
            "collapsed list unmounts its rows entirely. Tree:\n\(app.debugDescription)"
        )
        XCTAssertFalse(element("Sessions.List").exists, "collapsed list leaves no residue on the right")

        toggle.tap()
        XCTAssertTrue(
            element("Sessions.List").waitForExistence(timeout: 5),
            "toggle restores the list. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5), "session rows return after restore")
    }
}
