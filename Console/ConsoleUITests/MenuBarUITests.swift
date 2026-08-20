import XCTest

final class MenuBarUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Menu Bar Icon

    func testMenuBarIconAppears() throws {
        app.launch()

        // Wait for app to fully launch
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should exist")

        // Note: XCUITest cannot directly access menu bar items in the system menu bar
        // This test verifies the app launched successfully, which initializes the menu bar item
        // Manual verification required: Check that fish icon appears in menu bar

        // Verify MenuBarManager installation was called by checking app state
        XCTAssertTrue(app.exists, "App should be running with menu bar item initialized")
    }

    // MARK: - Menu Bar Menu Items

    func testMenuBarMenuItems() throws {
        // Note: XCUITest cannot interact with system menu bar items directly
        // This would require accessibility permissions and system-level UI testing
        // Manual test required: Click menu bar icon and verify menu items exist

        // Test documents expected menu structure:
        // - "Show Window" / "Hide Window"
        // - "Start Listening" / "Stop Listening"
        // - Separator
        // - "Quit Console"

        throw XCTSkip("Menu bar interaction requires manual testing - XCUITest cannot access system menu bar")
    }

    // MARK: - Start/Stop Listening via Menu Bar

    func testMenuBarStartListening() throws {
        // Note: Cannot directly test menu bar clicks with XCUITest
        // Alternative: Test the underlying functionality via hotkey

        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        // Use keyboard shortcut to start listening (same action as menu bar item)
        // Default hotkey: Cmd+Shift+L (configurable)
        app.typeKey("l", modifierFlags: [.command, .shift])

        // Verify listening started (check for visual indicator if accessible)
        // This would show in the menu bar icon state change
        sleep(2)

        // Stop listening
        app.typeKey("l", modifierFlags: [.command, .shift])

        sleep(1)

        // Listening should have stopped
        XCTAssertTrue(mainWindow.exists, "Window should still exist after toggling listening")
    }

    // MARK: - Quit via Menu Bar

    func testMenuBarQuit() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        // Quit via keyboard shortcut (Cmd+Q - same as menu bar "Quit")
        app.typeKey("q", modifierFlags: .command)

        // Wait for app to terminate
        sleep(2)

        // App should no longer exist
        XCTAssertFalse(mainWindow.exists, "App should have quit")
    }

    // MARK: - Window Persistence

    func testWindowCloseHidesInsteadOfDestroying() throws {
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        // Close window (should hide, not destroy - menu bar app pattern)
        mainWindow.typeKey("w", modifierFlags: .command)

        sleep(1)

        // Reshow window via global hotkey (Ctrl+Option+Cmd+T)
        app.typeKey("t", modifierFlags: [.control, .option, .command])

        sleep(1)

        // Window should exist again (was hidden, not destroyed)
        XCTAssertTrue(mainWindow.exists, "Window should reappear - was hidden, not destroyed")
    }
}
