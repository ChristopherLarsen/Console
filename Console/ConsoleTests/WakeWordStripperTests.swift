import XCTest
@testable import Console

final class WakeWordStripperTests: XCTestCase {

    // MARK: - Basic Wake Word Stripping

    func testStripSingleWakeWord() {
        let result = WakeWordStripper.stripWakeWord(
            from: "console open terminal",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(result, "open terminal")
    }

    func testStripMultiWordWakeWord() {
        let result = WakeWordStripper.stripWakeWord(
            from: "hey console open terminal",
            detectedWakeWord: "console",
            allWakeWords: ["hey console", "console"]
        )
        XCTAssertEqual(result, "open terminal")
    }

    func testStripWakeWordWithMultipleOccurrences() {
        // Should use the LAST occurrence
        let result = WakeWordStripper.stripWakeWord(
            from: "console please console open terminal",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(result, "open terminal")
    }

    // MARK: - Filler Word Handling

    func testStripFillerWords() {
        let testCases: [(input: String, expected: String)] = [
            ("console please open terminal", "open terminal"),
            ("console can you open terminal", "open terminal"),
            ("console i want to open terminal", "open terminal"),
            ("console could you please open terminal", "open terminal"),
            ("console the terminal please", "terminal please"),
        ]

        for testCase in testCases {
            let result = WakeWordStripper.stripWakeWord(
                from: testCase.input,
                detectedWakeWord: "console",
                allWakeWords: ["console"]
            )
            XCTAssertEqual(result, testCase.expected, "Failed for input: '\(testCase.input)'")
        }
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitivity() {
        let testCases: [(input: String, wake: String, expected: String)] = [
            ("CONSOLE open terminal", "console", "open terminal"),
            ("Console open terminal", "console", "open terminal"),
            ("console OPEN TERMINAL", "console", "OPEN TERMINAL"),
            ("HEY CONSOLE open terminal", "console", "open terminal"),
        ]

        for testCase in testCases {
            let result = WakeWordStripper.stripWakeWord(
                from: testCase.input,
                detectedWakeWord: testCase.wake,
                allWakeWords: [testCase.wake]
            )
            XCTAssertEqual(result, testCase.expected, "Failed for input: '\(testCase.input)'")
        }
    }

    // MARK: - Multi-Word Wake Words

    func testMultiWordWakeWords() {
        let result = WakeWordStripper.stripWakeWord(
            from: "okay console open safari",
            detectedWakeWord: "console",
            allWakeWords: ["ok console", "console"]
        )
        XCTAssertEqual(result, "open safari")
    }

    func testMultiWordWakeWordWithFillers() {
        let result = WakeWordStripper.stripWakeWord(
            from: "hey console please open safari",
            detectedWakeWord: "console",
            allWakeWords: ["hey console", "console"]
        )
        XCTAssertEqual(result, "open safari")
    }

    // MARK: - Edge Cases

    func testWakeWordOnly() {
        let result = WakeWordStripper.stripWakeWord(
            from: "console",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(result, "")
    }

    func testWakeWordWithFillersOnly() {
        let result = WakeWordStripper.stripWakeWord(
            from: "console please",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(result, "")
    }

    func testEmptyInput() {
        let result = WakeWordStripper.stripWakeWord(
            from: "",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(result, "")
    }

    func testWhitespaceOnly() {
        let result = WakeWordStripper.stripWakeWord(
            from: "   ",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        XCTAssertEqual(result, "")
    }

    func testNoWakeWordInText() {
        // If wake word not found, return original text
        let result = WakeWordStripper.stripWakeWord(
            from: "open terminal",
            detectedWakeWord: "console",
            allWakeWords: ["console"]
        )
        // Should return the command as-is since no wake word found
        XCTAssertEqual(result, "open terminal")
    }

    // MARK: - Real-World Examples

    func testRealWorldExamples() {
        let testCases: [(input: String, wake: String, allWakes: [String], expected: String)] = [
            // Natural speech patterns
            ("hey console open my downloads folder", "console", ["hey console", "console"], "open my downloads folder"),
            ("console turn on dark mode", "console", ["console"], "turn on dark mode"),
            ("okay console can you please open safari", "console", ["console"], "open safari"),

            // With fillers and hesitation
            ("console uh open terminal", "console", ["console"], "uh open terminal"),
            ("console um can you open safari", "console", ["console"], "um can you open safari"),

            // Commands with "the" article
            ("console open the terminal", "console", ["console"], "open the terminal"),

            // Complex multi-word commands
            ("console create a new folder on desktop", "console", ["console"], "create a new folder on desktop"),
            ("console set volume to fifty percent", "console", ["console"], "set volume to fifty percent"),

            // Multiple wake word variations
            ("hey console please turn on the lights", "console", ["hey console", "ok console", "console"], "turn on the lights"),
        ]

        for (index, testCase) in testCases.enumerated() {
            let result = WakeWordStripper.stripWakeWord(
                from: testCase.input,
                detectedWakeWord: testCase.wake,
                allWakeWords: testCase.allWakes
            )
            XCTAssertEqual(
                result,
                testCase.expected,
                "Failed test case #\(index): '\(testCase.input)' (wake: '\(testCase.wake)')"
            )
        }
    }

    // MARK: - Performance

    func testPerformance() {
        measure {
            for _ in 0..<1000 {
                _ = WakeWordStripper.stripWakeWord(
                    from: "hey console can you please open safari and navigate to google",
                    detectedWakeWord: "console",
                    allWakeWords: ["hey console", "ok console", "console"]
                )
            }
        }
    }

    // MARK: - Contains Wake Word Check

    func testContainsWakeWord() {
        XCTAssertTrue(
            WakeWordStripper.containsWakeWord("hey console open terminal", wakeWords: ["console"])
        )
        XCTAssertTrue(
            WakeWordStripper.containsWakeWord("ok console please", wakeWords: ["ok console", "console"])
        )
        XCTAssertFalse(
            WakeWordStripper.containsWakeWord("open terminal", wakeWords: ["console"])
        )
        XCTAssertTrue(
            WakeWordStripper.containsWakeWord("CONSOLE open terminal", wakeWords: ["console"])
        )
    }
}
