import XCTest
import SwiftData
@testable import Console

/// H05-F02 — a strictly higher-scoring match wins instead of being dropped by
/// the ambiguity guard; equal top scores across distinct commands stay ambiguous.
@MainActor
final class CommandMatcherWinnerTests: XCTestCase {

    // MARK: - CommandMatcher

    func testNestedPhraseClearWinnerIsReturned() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let open = Command(name: "Open", triggerPhrases: ["open"], isEnabled: true)
        let openSafari = Command(name: "Open Safari", triggerPhrases: ["open safari"], isEnabled: true)
        context.insert(open)
        context.insert(openSafari)

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let match = matcher.bestMatch(for: "open safari", in: [open, openSafari])

        XCTAssertNotNil(match, "Clear winner must not be dropped by the ambiguity guard")
        XCTAssertEqual(match?.command.name, "Open Safari")
    }

    func testEqualTopScoresStayAmbiguous() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let waveHello = Command(name: "Wave Hello", triggerPhrases: ["wave"], isEnabled: true)
        let oceanWave = Command(name: "Ocean Wave", triggerPhrases: ["wave"], isEnabled: true)
        context.insert(waveHello)
        context.insert(oceanWave)

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        XCTAssertNil(matcher.bestMatch(for: "wave", in: [waveHello, oceanWave]))
    }

    func testDuplicateNamedCommandsStillMatch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let wave1 = Command(name: "Wave", triggerPhrases: ["wave"], isEnabled: true)
        let wave2 = Command(name: "Wave", triggerPhrases: ["wave"], isEnabled: true)
        context.insert(wave1)
        context.insert(wave2)

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let match = matcher.bestMatch(for: "wave", in: [wave1, wave2])

        XCTAssertEqual(match?.command.name, "Wave")
        XCTAssertEqual(match?.confidence, 1.0)
    }

    // MARK: - ConsoleCommandMatcher

    func testConsoleMatcherExactPhraseStillWins() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)
        let match = matcher.bestMatch(for: "take a note", availableIn: .primary)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.command.name, "Take Note")
    }

    func testConsoleMatcherStopPhraseMatches() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)
        let match = matcher.bestMatch(for: "stop listening", availableIn: .primary)
        XCTAssertEqual(match?.command.name, "Stop Listening")
    }

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Command.self])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}