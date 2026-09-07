import XCTest
import SwiftData
@testable import Console

@MainActor
final class CommandMatcherTests: XCTestCase {

    private let targetPhrase = "Coca-Cola"

    private let variations: [(input: String, label: String)] = [
        ("Coca Cola",        "exact minus hyphen"),
        ("coca cola",        "lowercase"),
        ("Coca-Cola",        "exact match"),
        ("COCA COLA",        "all caps"),
        ("Coca  Cola",       "extra whitespace"),

        ("Coca Colaa",       "minor typo"),
        ("Cocoa Cola",       "common misspelling"),
        ("Coca Kola",        "alternate spelling"),
        ("CocaCola",         "no space"),
        ("Coca Cola drink",  "extra trailing word"),

        ("coke a cola",      "phonetic slang"),
        ("coca cola please", "speech padding"),
        ("the coca cola",    "article prefix"),
        ("open coca cola",   "verb prefix"),
        ("koka kola",        "full phonetic respelling"),

        ("cola",             "partial one token"),
        ("coke",             "slang abbreviation"),
        ("pepsi cola",       "different brand"),
        ("coca",             "partial one token 2"),
        ("soda pop",         "completely different"),
    ]

    private let thresholds: [Double] = [0.65, 0.70, 0.75, 0.80, 0.85]

    // MARK: - Results Matrix

    func testConfidenceThresholdMatrix() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)
        let normalizedTarget = matcher.normalize(targetPhrase)

        var scores: [Double] = []
        for variation in variations {
            let normalizedInput = matcher.normalize(variation.input)
            let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedTarget)
            scores.append(score)
        }

        print("")
        print("=== CommandMatcher Confidence Threshold Analysis ===")
        print("Target phrase: \"\(targetPhrase)\"")
        print("Normalized target: \"\(normalizedTarget)\"")
        print("")

        let labelWidth = 28

        var header = "Variation".padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        header += "| Score  "
        for t in thresholds {
            header += "| \(String(format: "%3d", Int(t * 100)))% "
        }
        print(header)

        let sep = String(repeating: "-", count: labelWidth)
            + "|--------"
            + String(repeating: "|------", count: thresholds.count)
        print(sep)

        for (i, variation) in variations.enumerated() {
            var row = variation.input.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            row += "| " + String(format: "%.3f", scores[i]).padding(toLength: 6, withPad: " ", startingAt: 0)
            for t in thresholds {
                let passes = scores[i] >= t
                row += "| " + (passes ? " Y  " : " -  ")
            }
            print(row)
        }

        print("")
        print("--- Summary ---")
        for t in thresholds {
            let matchCount = scores.filter { $0 >= t }.count
            print("  \(Int(t * 100))%: \(matchCount)/\(variations.count) variations matched")
        }
        print("")
    }

    // MARK: - Near-Identical Always Match at 90%

    func testNearIdenticalVariationsMatchAt90() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)
        let normalizedTarget = matcher.normalize(targetPhrase)

        let nearIdentical = [
            "Coca Cola",
            "coca cola",
            "Coca-Cola",
            "COCA COLA",
            "Coca  Cola",
        ]

        for input in nearIdentical {
            let normalizedInput = matcher.normalize(input)
            let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedTarget)
            XCTAssertGreaterThanOrEqual(
                score, 0.90,
                "Near-identical '\(input)' (score: \(score)) should meet 90% threshold"
            )
        }
    }

    // MARK: - Completely Different Never Matches

    func testCompletelyDifferentNeverMatches() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)
        let normalizedTarget = matcher.normalize(targetPhrase)
        let normalizedInput = matcher.normalize("soda pop")

        let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedTarget)
        XCTAssertLessThan(
            score, 0.50,
            "'soda pop' (score: \(score)) should not reach 50% threshold"
        )
    }

    // MARK: - Phraseless duplicate does not shadow the original (H06-F02)

    func testPhraselessDuplicateKeepsOriginalVoiceMatchable() {
        let matcher = CommandMatcher()
        let original = Command(
            name: "Synthetic Original",
            triggerPhrases: ["synthetic voice phrase"],
            actions: [CommandAction(type: .appleScript, payload: "return \"ok\"", order: 0)]
        )
        let copy = original.duplicating()
        copy.triggerPhrases = []

        let match = matcher.bestMatch(for: "synthetic voice phrase", in: [original, copy])

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.command.id, original.id)
    }

    // MARK: - Exact Match Returns 1.0

    func testExactMatchReturnsFullConfidence() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)
        let normalizedTarget = matcher.normalize(targetPhrase)
        let normalizedInput = matcher.normalize("Coca-Cola")

        let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedTarget)
        XCTAssertEqual(score, 1.0, "Exact match should return confidence 1.0")
    }

    // MARK: - Single-Word Command Matching ("console wave" → "wave")

    func testSingleWordExactMatch_Wave() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let score = matcher.calculateConfidence(input: "wave", phrase: "wave")
        XCTAssertEqual(score, 1.0, "Exact single-word match should return 1.0")
    }

    func testSingleWordMatchAfterNormalization_Wave() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)
        let normalizedInput = matcher.normalize("wave")
        let normalizedPhrase = matcher.normalize("wave")
        let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedPhrase)
        XCTAssertEqual(score, 1.0, "Normalized 'wave' vs 'wave' should be 1.0")
    }

    func testSingleWordWithPunctuation_Wave() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)
        let normalizedInput = matcher.normalize("wave.")
        let normalizedPhrase = matcher.normalize("wave")
        let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedPhrase)
        XCTAssertEqual(score, 1.0, "Normalized 'wave.' should match 'wave' at 1.0")
    }

    func testSingleWordDoesNotCrossMatch() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let unrelatedPhrases = ["save", "wake", "cave", "pave", "stop", "note", "settings"]
        for phrase in unrelatedPhrases {
            let score = matcher.calculateConfidence(input: "wave", phrase: phrase)
            XCTAssertLessThan(
                score, 0.75,
                "'wave' should NOT match '\(phrase)' at 75% (got \(score))"
            )
        }
    }

    func testStrippedWaveMatchesCommandPhrase() async {
        let stripped = WakeWordStripper.stripWakeWord(
            from: "console wave",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(stripped, "wave", "Stripping 'console' from 'console wave' should yield 'wave'")

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let normalizedInput = matcher.normalize(stripped)
        let normalizedPhrase = matcher.normalize("wave")
        let score = matcher.calculateConfidence(input: normalizedInput, phrase: normalizedPhrase)
        XCTAssertEqual(score, 1.0, "Stripped + normalized 'wave' should match phrase 'wave' at 1.0")
    }

    // MARK: - bestMatch Ambiguity Guard

    func testBestMatchWithMultipleCommands() async {
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let waveCommand = Command(name: "Wave", triggerPhrases: ["wave"], isEnabled: true)
        let stopCommand = Command(name: "Stop", triggerPhrases: ["stop"], isEnabled: true)
        let settingsCommand = Command(name: "Settings", triggerPhrases: ["settings"], isEnabled: true)

        context.insert(waveCommand)
        context.insert(stopCommand)
        context.insert(settingsCommand)

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let result = matcher.bestMatch(for: "wave", in: [waveCommand, stopCommand, settingsCommand])
        XCTAssertNotNil(result, "bestMatch should find the 'wave' command")
        XCTAssertEqual(result?.command.name, "Wave")
        XCTAssertEqual(result?.confidence, 1.0)
    }

    func testBestMatchWithDuplicateCommands() async {
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let wave1 = Command(name: "Wave", triggerPhrases: ["Wave"], isEnabled: true)
        let wave2 = Command(name: "Wave", triggerPhrases: ["Wave"], isEnabled: true)
        let wave3 = Command(name: "Wave", triggerPhrases: ["Wave"], isEnabled: true)
        context.insert(wave1)
        context.insert(wave2)
        context.insert(wave3)

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let result = matcher.bestMatch(for: "wave", in: [wave1, wave2, wave3])
        XCTAssertNotNil(result, "Duplicate commands with the same name should not trigger ambiguity guard")
        XCTAssertEqual(result?.command.name, "Wave")
        XCTAssertEqual(result?.confidence, 1.0)
    }

    func testBestMatchRejectsGenuineAmbiguity() async {
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let waveHello = Command(name: "Wave Hello", triggerPhrases: ["wave"], isEnabled: true)
        let oceanWave = Command(name: "Ocean Wave", triggerPhrases: ["wave"], isEnabled: true)
        context.insert(waveHello)
        context.insert(oceanWave)

        let matcher = CommandMatcher(confidenceThreshold: 0.75)
        let result = matcher.bestMatch(for: "wave", in: [waveHello, oceanWave])
        XCTAssertNil(result, "Two differently-named commands matching the same phrase should be ambiguous")
    }

    // MARK: - Normalization

    func testNormalizationStripsHyphenAndCase() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)

        let result1 = matcher.normalize("Coca-Cola")
        let result2 = matcher.normalize("coca cola")
        XCTAssertEqual(result1, result2, "Hyphenated and spaced forms should normalize identically")
    }

    func testNormalizationCollapsesWhitespace() async {
        let matcher = CommandMatcher(confidenceThreshold: 0.0)

        let result1 = matcher.normalize("Coca  Cola")
        let result2 = matcher.normalize("coca cola")
        XCTAssertEqual(result1, result2, "Extra whitespace should be collapsed")
    }
}
