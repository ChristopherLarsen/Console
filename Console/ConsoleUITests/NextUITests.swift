import XCTest

/// Next destination: one shared model, sibling Refresh/Open controls, synthetic
/// panel sources only — never a live provider or company WebView.
final class NextUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForCheckCount(_ expected: Int, timeout: TimeInterval = 8) {
        let count = element("NextTaskCheckCount")
        XCTAssertTrue(
            count.waitForExistence(timeout: timeout),
            "Check count should be exposed. Tree:\n\(app.debugDescription)"
        )
        let predicate = NSPredicate(format: "value == %@", "\(expected)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: count)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected check count \(expected), last value \(count.value ?? "nil"). Tree:\n\(app.debugDescription)"
        )
    }

    /// Menu bar is outside the overlapping Codex window that intercepts content clicks.
    private func chooseGoMenu(_ title: String) {
        app.activate()
        let item = app.menuItems[title]
        if item.waitForExistence(timeout: 1) {
            item.click()
            return
        }
        let go = app.menuBars.menuBarItems["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 5), "Go menu should exist")
        go.click()
        XCTAssertTrue(
            app.menuItems[title].waitForExistence(timeout: 5),
            "Go menu should contain \(title). Tree:\n\(app.debugDescription)"
        )
        app.menuItems[title].click()
    }

    func testSharedModelShowsCheckingThenResultAndSplitsRefreshFromOpen() throws {
        app.launchArguments.append("-uiTestSelectNext")
        app.launchArguments.append("-uiTestNextSyntheticSources")
        app.launch()
        app.activate()

        XCTAssertTrue(
            element("NextView").waitForExistence(timeout: 12),
            "Next destination should be visible. Tree:\n\(app.debugDescription)"
        )

        let open = app.buttons["NextTaskOpenButton"]
        let refresh = app.buttons["NextTaskRefreshButton"]
        let determine = app.buttons["NextView.DetermineButton"]

        XCTAssertTrue(
            open.waitForExistence(timeout: 8),
            "Opening Next shows the result on the shared card. Tree:\n\(app.debugDescription)"
        )
        waitForCheckCount(1)
        XCTAssertTrue(
            open.label.contains("Review !42 in FixtureRepo"),
            "Synthetic local recommendation is on the Open control. Label: \(open.label)"
        )
        XCTAssertTrue(refresh.waitForExistence(timeout: 3), "Ready card exposes Refresh as a sibling control")
        XCTAssertEqual(refresh.label, "Refresh next task")
        XCTAssertTrue(
            open.label.contains("Open next task"),
            "Open has an explicit accessibility label. Label: \(open.label)"
        )
        XCTAssertTrue(determine.waitForExistence(timeout: 3), "Page-level refresh affordance is present")

        chooseGoMenu("Refresh Next Task")
        XCTAssertTrue(open.waitForExistence(timeout: 8), "Refresh updates the same card")
        waitForCheckCount(2)
        XCTAssertTrue(element("NextView").exists, "Refresh does not navigate away from Next")
        XCTAssertTrue(app.buttons["Next"].firstMatch.isSelected, "Refresh leaves Next selected")

        chooseGoMenu("Home")
        XCTAssertTrue(element("HomeDashboard").waitForExistence(timeout: 8), "Left Next for Home")

        chooseGoMenu("Next")
        XCTAssertTrue(element("NextView").waitForExistence(timeout: 8), "Re-entered Next")
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Cached result is still on the card")
        waitForCheckCount(2)
        XCTAssertFalse(
            element("NextTaskChecking").waitForExistence(timeout: 1.2),
            "Re-entering within the freshness window must not start another check"
        )

        chooseGoMenu("Open Next Task")
        XCTAssertTrue(
            app.buttons["GitLab"].firstMatch.waitForExistence(timeout: 5),
            "GitLab sidebar item remains visible after Open"
        )
        XCTAssertTrue(
            app.buttons["GitLab"].firstMatch.isSelected
                || element("MergeRequestsEmptyState").waitForExistence(timeout: 5)
                || element("MergeRequestsWebView").exists
                || app.staticTexts["Set Web View GitLab Reviews URL in Settings"].exists
                || app.staticTexts["Set Web View GitLab My MRs URL in Settings"].exists,
            "Opening the result navigates to GitLab. Tree:\n\(app.debugDescription)"
        )
        XCTAssertFalse(element("NextView").exists, "Open leaves the Next destination")
    }
}
