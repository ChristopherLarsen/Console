import XCTest
import AppKit
import Network

private final class BrowserLinkFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BrowserLinkFixtureServer")
    var port: UInt16? { listener.port?.rawValue }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready() }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let text = request.contains("GET /clipboard ") ? "Clipboard destination loaded" : "Browser fixture page"
                let html = "<html><body style='padding:40px'><h1>\(text)</h1><a href='/destination'><span>Browser fixture link</span></a></body></html>"
                let body = Data(html.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }
}

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

    @MainActor
    func testJiraLinkContextMenuAndNewTabInput() throws {
        try verifyBrowserLinkMenuAndNewTabInput(destination: "jira", fieldID: "Jira.URLField", pinnedCount: 1)
    }

    @MainActor
    func testGitLabLinkContextMenuAndNewTabInput() throws {
        try verifyBrowserLinkMenuAndNewTabInput(destination: "mergeRequests", fieldID: "MergeRequests.URLField", pinnedCount: 2)
    }

    @MainActor
    private func verifyBrowserLinkMenuAndNewTabInput(destination: String, fieldID: String, pinnedCount: Int) throws {
        let server = try BrowserLinkFixtureServer()
        let ready = expectation(description: "Local browser fixture ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(try XCTUnwrap(server.port))"
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        defer {
            app.terminate()
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        app.launchArguments = ["-uiTestInMemoryStore", "-sidebarSelection", destination,
            "-webViewJiraURL", base, "-webViewGitLabReviewsURL", base,
            "-mrScanEnabled", "NO", "-listenOnStartup", "NO", "-isTerminalExpanded", "NO"]
        app.launch()
        let link = app.links["Browser fixture link"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.rightClick()
        let menuItem = app.menuItems["Open Link in New Tab"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Must appear in the webpage link's actual right-click menu")
        menuItem.click()
        let field = app.textFields[fieldID].firstMatch
        let destinationURL = base + "/destination"
        expectation(for: NSPredicate(format: "value == %@", destinationURL), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.descendants(matching: .any)["BrowserTabBar.Tab.\(pinnedCount)"].firstMatch.exists)

        // Return to the original tab: its URL must not have been replaced.
        app.descendants(matching: .any)["BrowserTabBar.Tab.0"].firstMatch.click()
        expectation(for: NSPredicate(format: "value == %@ OR value == %@", base, base + "/"), evaluatedWith: field)
        waitForExpectations(timeout: 10)

        pasteboard.clearContents()
        pasteboard.setString("not a URL", forType: .string)
        app.buttons["BrowserTabBar.NewTabButton"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Type without clicking the field: proves real keyboard focus.
        app.typeText(base + "/typed")
        expectation(for: NSPredicate(format: "value == %@", base + "/typed"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeKey(.return, modifierFlags: [])

        pasteboard.clearContents()
        pasteboard.setString(base + "/clipboard", forType: .string)
        app.typeKey("t", modifierFlags: .command)
        expectation(for: NSPredicate(format: "value == %@", base + "/clipboard"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Clipboard destination loaded"].firstMatch.waitForExistence(timeout: 10),
                      "Clipboard URL must actually load, not merely appear in the field")
    }

    func testSidebarHasPrimaryItems() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 5), "Home sidebar item should be visible")
        XCTAssertTrue(app.buttons["JIRA"].firstMatch.exists, "JIRA sidebar item should be visible")
        XCTAssertTrue(app.buttons["GitLab"].firstMatch.exists, "GitLab sidebar item should be visible")
        XCTAssertFalse(app.buttons["Triggers"].exists, "Triggers sidebar item was consolidated into Commands")
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

        let mergeRequestsURLLabel = app.staticTexts["GitLab URL"].firstMatch
        XCTAssertTrue(mergeRequestsURLLabel.waitForExistence(timeout: 5), "Settings should show GitLab URL field")

        // New GitLab list fields share the URL's section.
        let gitLabReviewsURLLabel = app.staticTexts["GitLab Reviews URL"].firstMatch
        XCTAssertTrue(gitLabReviewsURLLabel.waitForExistence(timeout: 5), "Settings should show GitLab Reviews URL field")

        let gitLabMyMRsURLLabel = app.staticTexts["GitLab My MRs URL"].firstMatch
        XCTAssertTrue(gitLabMyMRsURLLabel.waitForExistence(timeout: 5), "Settings should show GitLab My MRs URL field")
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

    func testCommandsSidebarShowsConsolidatedHub() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should appear")

        let commandsItem = app.buttons["Commands"].firstMatch
        XCTAssertTrue(commandsItem.waitForExistence(timeout: 5))
        commandsItem.tap()

        // Consolidated hub: the segmented Triggers/Commands picker renders
        // above the command list.
        let triggersSegment = app.descendants(matching: .any).matching(identifier: "CommandsHubSegmented").firstMatch
        XCTAssertTrue(triggersSegment.waitForExistence(timeout: 5), "Commands hub segmented control should be visible")
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

    func testMainTerminalSidebarItemTogglesDrawer() throws {
        // Synthesized clicks on custom sidebar rows never actuate on this
        // host (documented dead end), so the toggle itself is driven by a
        // DEBUG launch hook performing the sidebar row's action; the test
        // asserts the sidebar item exists and the drawer unmounts/remounts.
        app.launchArguments += ["-uiTestExpandTerminal", "-uiTestAutoToggleTerminal"]
        app.launch()

        let mainTerminalItem = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(mainTerminalItem.waitForExistence(timeout: 5), "Terminal sidebar item should be visible above Settings")

        let drawer = app.descendants(matching: .any).matching(identifier: "MainTerminalDrawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "Drawer content should be visible when expanded")

        XCTAssertTrue(
            drawer.waitForNonExistence(timeout: 10),
            "Toggle should unmount the drawer entirely, freeing its space. Tree:\n\(app.debugDescription)"
        )

        // Relaunch: the persisted retracted preference must not block the
        // drawer from expanding again.
        app.terminate()
        app.launchArguments = ["-uiTestExpandTerminal"]
        app.launch()
        let mainTerminalItem2 = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(mainTerminalItem2.waitForExistence(timeout: 5), "Terminal sidebar item persists across launches")
        let drawer2 = app.descendants(matching: .any).matching(identifier: "MainTerminalDrawer").firstMatch
        XCTAssertTrue(drawer2.waitForExistence(timeout: 5), "Drawer should expand again on a later launch")
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

    // MARK: - Keyboard developer actions (item 23)

    func testDeveloperActionPickerKeyboardAndEscapeLeaveGoShortcutsAlone() throws {
        app.launch()
        app.activate()

        // Menu bar is reachable even when the main surface is an AX dialog.
        let develop = app.menuBars.menuBarItems["Develop"]
        XCTAssertTrue(develop.waitForExistence(timeout: 12), "Develop menu should exist")
        develop.click()
        XCTAssertTrue(app.menuItems["Focus Current Session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["New General Session"].exists)
        XCTAssertTrue(app.menuItems["Open Workspace in Xcode"].exists)
        XCTAssertTrue(app.menuItems["Build Selected Profile"].exists)
        XCTAssertTrue(app.menuItems["Run Selected Tests"].exists)
        XCTAssertTrue(app.menuItems["Open Latest Result"].exists)
        XCTAssertTrue(app.menuItems["Run in Selected Simulator"].exists)
        let launcher = app.menuItems["Developer Actions…"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 3), "Picker command should be in the Develop menu")
        launcher.click()

        let picker = app.descendants(matching: .any)["DeveloperActions.Picker"].firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8),
            "Action picker should open. Tree:\n\(app.debugDescription)"
        )
        let search = app.textFields["DeveloperActions.Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Picker search field should exist")
        if search.isHittable { search.click() }
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            app.descendants(matching: .any)["DeveloperActions.Preview"].firstMatch.waitForExistence(timeout: 5),
            "Keyboard selection should keep the action preview visible"
        )
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: dismissed, object: picker)
        XCTAssertEqual(
            XCTWaiter.wait(for: [wait], timeout: 5),
            .completed,
            "Escape should dismiss the picker"
        )

        let go = app.menuBars.menuBarItems["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 5), "Go menu should still exist")
        go.click()
        XCTAssertTrue(app.menuItems["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Session 1"].exists, "⌘1 session shortcut must remain on Go")
        XCTAssertTrue(app.menuItems["Focus Session"].exists, "⌘⇧F must remain Focus Session on Go")
        app.typeKey(.escape, modifierFlags: [])

        // Navigate away from Home first, or the assert below would pass
        // without ⌃1 doing anything (the app always launches on Home).
        // Synthesized clicks into the main window do not actuate on this
        // host, so relaunch with the launch-argument navigation fixture.
        app.terminate()
        app.launchArguments.append("-uiTestSelectTriggers")
        app.launch()

        let awayDashboard = app.descendants(matching: .any)["HomeDashboard"].firstMatch
        XCTAssertFalse(
            awayDashboard.waitForExistence(timeout: 2),
            "Precondition: should not be on Home before pressing ⌃1"
        )

        app.typeKey("1", modifierFlags: [.control])
        let homeDashboard = app.descendants(matching: .any)["HomeDashboard"].firstMatch
        XCTAssertTrue(
            homeDashboard.waitForExistence(timeout: 8),
            "⌃1 must return to Home"
        )
    }
}
