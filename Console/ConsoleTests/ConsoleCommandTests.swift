import XCTest
@testable import Console

@MainActor
final class ConsoleCommandTests: XCTestCase {

    // MARK: - Exact Matching

    func testExactMatch() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)
        let match = matcher.bestMatch(for: "off", availableIn: .primary)

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.command.id, "stop-listening")
        XCTAssertEqual(match?.confidence, 1.0)
    }

    // MARK: - Fuzzy Matching

    func testFuzzyMatch() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)
        let match = matcher.bestMatch(for: "stop listen", availableIn: .primary)

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.command.id, "stop-listening")
    }

    // MARK: - Confidence Scoring

    func testIdenticalInputScoresPerfect() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)
        let score = matcher.calculateConfidence(input: "off", phrase: "off")
        XCTAssertEqual(score, 1.0)
    }

    func testCompletelyDifferentInputScoresLow() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)
        let score = matcher.calculateConfidence(input: "xylophone", phrase: "off")
        XCTAssertLessThan(score, 0.75)
    }

    // MARK: - Mode Filtering

    func testModeFiltering() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)

        // "done" is only available in .exclusive mode
        let matchInExclusive = matcher.bestMatch(for: "done", availableIn: .exclusive)
        let matchInPrimary = matcher.bestMatch(for: "done", availableIn: .primary)

        XCTAssertNotNil(matchInExclusive)
        XCTAssertNil(matchInPrimary)
    }

    // MARK: - No Ambiguity

    func testNoAmbiguousMatches() {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.75)

        let matches = matcher.findMatches(for: "off", availableIn: .primary)
        let uniqueCommandIds = Set(matches.map { $0.command.id })

        XCTAssertEqual(uniqueCommandIds.count, 1, "Multiple commands matched the same phrase")
    }

    // MARK: - Registry

    func testRegistryContainsAllCommands() {
        let all = ConsoleCommandRegistry.all
        XCTAssertGreaterThan(all.count, 0)

        let ids = all.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate command IDs in registry")
    }

    func testRegistryFindById() {
        XCTAssertNotNil(ConsoleCommandRegistry.find(by: "stop-listening"))
        XCTAssertNil(ConsoleCommandRegistry.find(by: "nonexistent-command"))
    }
}
