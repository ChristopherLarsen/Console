import XCTest

final class SpeechPipelineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helper

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

    // MARK: - Test 1: Positive — "Console Commands"

    func testFishCommandsShowsPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "commands")
        ])
        app.launch()

        let panel = app.windows["CommandsPanel"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 8),
            "CommandsPanel should appear after 'console commands'"
        )
    }

    // MARK: - Test 2: Negative — "Popcorn time"

    func testPopcornTimeDoesNotTrigger() throws {
        let app = XCUIApplication()
        app.launchArguments = syntheticSpeechArgs([
            (1.0, "popcorn"),
            (1.5, "time")
        ])
        app.launch()

        // Wait long enough for the synthetic source to finish
        sleep(6)

        let panel = app.windows["CommandsPanel"]
        XCTAssertFalse(
            panel.exists,
            "CommandsPanel should NOT appear for non-wake-word speech"
        )
    }

    // MARK: - Test 3: Positive trigger, no matching command — "Console leviathan"

    func testFishLeviathanDoesNotShowPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = syntheticSpeechArgs([
            (1.0, "console"),
            (1.2, "leviathan")
        ])
        app.launch()

        // Wait for pipeline to process, finalize, and return to passive
        sleep(6)

        let panel = app.windows["CommandsPanel"]
        XCTAssertFalse(
            panel.exists,
            "CommandsPanel should NOT appear for unrecognized command 'leviathan'"
        )
    }
}
