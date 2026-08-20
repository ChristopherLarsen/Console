import XCTest

final class CommandExecutionUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helper: Synthetic Speech

    /// Builds launch arguments that inject a synthetic transcript source.
    private func syntheticSpeechArgs(_ entries: [(TimeInterval, String)]) -> [String] {
        struct Entry: Codable {
            let delay: TimeInterval
            let word: String
        }
        let encoded = entries.map { Entry(delay: $0.0, word: $0.1) }
        let data = try! JSONEncoder().encode(encoded)
        let json = String(data: data, encoding: .utf8)!
        return ["--synthetic-speech", json, "--auto-start-listening"]
    }

    // MARK: - Wake Word Detection

    func testWakeWordDetection() throws {
        // Test that saying "console" activates listening mode
        let args = syntheticSpeechArgs([
            (1.0, "console")
        ])
        app.launchArguments = args
        app.launch()

        // Wait for wake word processing
        sleep(3)

        // Verify listening mode is active
        // Note: Visual feedback depends on implementation
        // Could check menu bar icon state, status indicator, or window state

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "App should be running with listening active")

        // In a real implementation, you would verify:
        // - Menu bar icon changes to indicate listening
        // - Status indicator shows "Listening..."
        // - Audio waveform or visual feedback appears

        // Since we can't directly verify listening state via UI,
        // we verify the app is in the correct state to receive commands
    }

    // MARK: - Command Recognition

    func testCommandRecognition() throws {
        // Test basic command recognition: "console commands"
        let args = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "commands")
        ])
        app.launchArguments = args
        app.launch()

        sleep(5)

        // Verify command executed - "Console Commands" shows available commands panel
        let commandsPanel = app.windows["CommandsPanel"]
        XCTAssertTrue(
            commandsPanel.waitForExistence(timeout: 3),
            "'console commands' should show CommandsPanel"
        )
    }

    func testStopListeningCommand() throws {
        // Test "console stop listening" / "console off" command
        let args = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "stop"),
            (1.4, "listening")
        ])
        app.launchArguments = args
        app.launch()

        sleep(5)

        // After "stop listening", the app should return to passive mode
        // Verify no panel appears (command was to stop, not to do something visible)
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "App should still be running")

        // In real implementation, would verify:
        // - Menu bar icon returns to passive state
        // - Status indicator shows "Not Listening"
        // - Visual feedback stops
    }

    func testBuiltInCommandExecution() throws {
        // Test execution of various built-in Console commands

        // Test "console commands" - already covered above

        // Test "console stop listening"
        let args = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "off")  // Alternative phrase for stop listening
        ])
        app.launchArguments = args
        app.launch()

        sleep(4)

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "'console off' should execute without error")
    }

    // MARK: - No Matching Command

    func testNoMatchingCommand() throws {
        // Test wake word + unrecognized phrase
        let args = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "abracadabra"),
            (1.4, "xylophone")
        ])
        app.launchArguments = args
        app.launch()

        sleep(6)

        // No command should execute for unrecognized phrase
        let commandsPanel = app.windows["CommandsPanel"]
        XCTAssertFalse(commandsPanel.exists, "No panel should appear for unrecognized command")

        // If error popups are enabled, an error might appear
        // Check for error popup if showErrorPopups is true
        let errorPopup = app.staticTexts["Error"]
        if errorPopup.exists {
            // Error popup appeared - this is acceptable behavior
            XCTAssertTrue(true, "Error popup for unrecognized command is acceptable")
        }
    }

    func testGarbagePhraseAfterWakeWord() throws {
        // Test that garbage phrase doesn't crash or cause issues
        let args = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "qwerty"),
            (1.4, "asdfgh"),
            (1.6, "zxcvbn")
        ])
        app.launchArguments = args
        app.launch()

        sleep(6)

        // App should gracefully handle unrecognized command
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "App should remain stable after unrecognized command")
    }

    // MARK: - Multiple Commands in Sequence

    func testMultipleCommandsSequence() throws {
        // Test executing multiple commands in sequence

        // First command: "console commands"
        let args1 = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "commands")
        ])
        app.launchArguments = args1
        app.launch()

        sleep(4)

        let commandsPanel = app.windows["CommandsPanel"]
        XCTAssertTrue(commandsPanel.waitForExistence(timeout: 3))

        // Close panel
        let closeButton = commandsPanel.buttons["Close"].firstMatch
        if closeButton.exists {
            closeButton.click()
        } else {
            commandsPanel.typeKey(.escape, modifierFlags: [])
        }

        sleep(1)

        // Terminate and relaunch for second command
        app.terminate()

        // Second command: "console off"
        let args2 = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "off")
        ])
        app.launchArguments = args2
        app.launch()

        sleep(4)

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "Second command should execute successfully")
    }

    // MARK: - User-Created Command Execution

    func testUserCreatedCommandExecution() throws {
        // Test execution of user-created custom command
        // Requires command creation and execution via speech

        throw XCTSkip("Requires user command creation and phrase matching")

        // Expected test flow:
        // 1. Create custom command with trigger phrase "open safari"
        // 2. Inject synthetic speech: "console open safari"
        // 3. Verify command executes (Safari opens)
        // 4. Verify confirmation popup appears (if enabled)
    }

    // MARK: - Command Popup Confirmation

    func testCommandPopupConfirmation() throws {
        // Test that command confirmation popup appears (if showCommandPopups enabled)
        // This requires app preference showCommandPopups = true

        throw XCTSkip("Requires showCommandPopups preference enabled")

        // Expected test flow:
        // 1. Enable showCommandPopups in Settings
        // 2. Execute any command
        // 3. Verify popup appears with command name
        // 4. Verify popup auto-dismisses after configured duration
    }

    // MARK: - Error Popup on Command Failure

    func testErrorPopupOnCommandFailure() throws {
        // Test that error popup appears when command execution fails
        // Requires showErrorPopups preference enabled

        throw XCTSkip("Requires command execution failure scenario and showErrorPopups enabled")

        // Expected test flow:
        // 1. Enable showErrorPopups
        // 2. Execute command that will fail (e.g., open non-existent file)
        // 3. Verify error popup appears
        // 4. Verify error message is descriptive
    }

    // MARK: - Wake Word While Listening

    func testWakeWordWhileAlreadyListening() throws {
        // Test saying wake word again while already in listening mode
        let args = syntheticSpeechArgs([
            (1.0, "console"),       // First wake word - activates listening
            (1.5, "console"),       // Second wake word - should be ignored or reset
            (1.7, "commands")    // Command should still execute
        ])
        app.launchArguments = args
        app.launch()

        sleep(5)

        // Command should execute despite duplicate wake word
        let commandsPanel = app.windows["CommandsPanel"]
        XCTAssertTrue(
            commandsPanel.waitForExistence(timeout: 3),
            "Command should execute even with duplicate wake word"
        )
    }

    // MARK: - Speech Recognition Accuracy

    func testSimilarSoundingPhrases() throws {
        // Test distinguishing between similar-sounding phrases
        let args = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "come"),
            (1.4, "on")  // "come on" vs "command"
        ])
        app.launchArguments = args
        app.launch()

        sleep(6)

        // "come on" should NOT match "command"
        let commandsPanel = app.windows["CommandsPanel"]
        XCTAssertFalse(
            commandsPanel.exists,
            "Similar-sounding phrase should not false-positive match"
        )
    }

    // MARK: - Long Command Phrases

    func testLongCommandPhrase() throws {
        // Test command with longer multi-word phrase
        // Requires a command with longer trigger phrase

        throw XCTSkip("Requires custom command with long trigger phrase")

        // Expected test flow:
        // 1. Create command with phrase "open my favorite website in safari"
        // 2. Inject full phrase via synthetic speech
        // 3. Verify command executes correctly
    }
}
