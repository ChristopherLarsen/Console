import XCTest

final class NoteDictationUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helper: Synthetic Speech for Note Dictation

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

    // TODO: - Test Note Panel Window

    // MARK: - Note Dictation

    func testNoteDictation() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Note Persistence

    func testNotePersistence() throws {
        throw XCTSkip("TODO: Develop test")
    }

    // MARK: - Note Formatting

    func testNoteFormattingToggle() throws {
        // If note formatting is enabled, test that it processes dictated text
        throw XCTSkip("Requires AI provider configuration and note formatting feature setup")

        // Expected:
        // 1. Enable noteFormattingEnabled in AppStorage
        // 2. Dictate text
        // 3. Trigger formatting (automatic or manual)
        // 4. Verify "Formatting..." indicator appears
        // 5. Verify text is formatted via LLM
    }

    // MARK: - Note Error Handling

    func testNoteFormattingError() throws {
        // Test error banner when formatting fails
        throw XCTSkip("Requires AI provider misconfiguration to trigger format error")

        // Expected:
        // 1. Enable formatting
        // 2. Configure invalid AI provider
        // 3. Attempt formatting
        // 4. Verify error banner appears in note panel
        // 5. Verify error can be dismissed
    }

    // MARK: - Note Panel Close Methods

    func testNotePanelCloseButton() throws {
        // Test X close button
        throw XCTSkip("Requires manual note panel trigger")

        // Expected: Panel closes when X button clicked
    }

    func testNotePanelEscapeKey() throws {
        // Test Escape key closes panel
        throw XCTSkip("Requires manual note panel trigger")

        // Expected: Panel closes on Escape
    }

    // MARK: - Note During Active Listening

    func testNoteWhileListening() throws {
        throw XCTSkip("TODO: Develop test")
    }
}
