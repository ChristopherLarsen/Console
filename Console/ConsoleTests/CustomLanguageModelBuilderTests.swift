import XCTest
@testable import Console

@MainActor
final class CustomLanguageModelBuilderTests: XCTestCase {

    private var builder: CustomLanguageModelBuilder!

    override func setUp() {
        super.setUp()
        builder = CustomLanguageModelBuilder.shared
    }

    // MARK: - collectVocabulary

    func testCollectVocabularyBasicInput() {
        let commands = [
            Command(
                name: "Open Terminal",
                triggerPhrases: ["open terminal", "launch terminal"]
            )
        ]

        let snapshot = builder!.collectVocabulary(
            wakeWords: ["Console"],
            commands: commands
        )

        XCTAssertEqual(snapshot.wakeWords, ["console"])
        XCTAssertEqual(Set(snapshot.commandPhrases), Set(["open terminal", "launch terminal"]))

        let expectedWords: Set<String> = ["open", "terminal", "launch", "console"]
        XCTAssertEqual(snapshot.individualWords, expectedWords)
    }

    func testCollectVocabularyEmptyInput() {
        let snapshot = builder!.collectVocabulary(wakeWords: [], commands: [])

        XCTAssertTrue(snapshot.wakeWords.isEmpty)
        XCTAssertTrue(snapshot.commandPhrases.isEmpty)
        XCTAssertTrue(snapshot.individualWords.isEmpty)

        let hash1 = snapshot.hashValue
        let hash2 = snapshot.hashValue
        XCTAssertEqual(hash1, hash2, "Hash should be deterministic for same snapshot")
    }

    func testCollectVocabularyMultiWordWakeWord() {
        let snapshot = builder!.collectVocabulary(
            wakeWords: ["Hey Console"],
            commands: []
        )

        XCTAssertEqual(snapshot.wakeWords, ["hey console"])
        XCTAssertTrue(snapshot.individualWords.contains("hey"))
        XCTAssertTrue(snapshot.individualWords.contains("console"))
    }

    func testCollectVocabularyLowercasesAndDeduplicates() {
        let commands = [
            Command(
                name: "Open Terminal",
                triggerPhrases: ["OPEN terminal"]
            ),
            Command(
                name: "Launch Terminal",
                triggerPhrases: ["open TERMINAL"]
            )
        ]

        let snapshot = builder!.collectVocabulary(
            wakeWords: ["CONSOLE"],
            commands: commands
        )

        XCTAssertEqual(snapshot.wakeWords, ["console"])
        XCTAssertEqual(Set(snapshot.commandPhrases), Set(["open terminal", "open terminal"]))
        XCTAssertEqual(snapshot.individualWords, Set(["open", "terminal", "console"]))
    }

    // MARK: - Hash stability

    func testHashChangesWithDifferentVocabulary() {
        let snap1 = builder!.collectVocabulary(
            wakeWords: ["console"],
            commands: []
        )
        let snap2 = builder!.collectVocabulary(
            wakeWords: ["computer"],
            commands: []
        )

        XCTAssertNotEqual(snap1.hashValue, snap2.hashValue)
    }

    func testHashStableForSameInputDifferentOrder() {
        let commands1 = [
            Command(name: "A", triggerPhrases: ["open terminal"]),
            Command(name: "B", triggerPhrases: ["dark mode"])
        ]
        let commands2 = [
            Command(name: "B", triggerPhrases: ["dark mode"]),
            Command(name: "A", triggerPhrases: ["open terminal"])
        ]

        let snap1 = builder!.collectVocabulary(wakeWords: ["console", "computer"], commands: commands1)
        let snap2 = builder!.collectVocabulary(wakeWords: ["computer", "console"], commands: commands2)

        XCTAssertEqual(snap1.hashValue, snap2.hashValue)
    }

    func testHashStableAcrossInvocations() {
        let commands = [Command(name: "Test", triggerPhrases: ["open browser"])]
        let snap1 = builder!.collectVocabulary(wakeWords: ["console"], commands: commands)
        let snap2 = builder!.collectVocabulary(wakeWords: ["console"], commands: commands)

        XCTAssertEqual(snap1.hashValue, snap2.hashValue)
    }

    func testCollectVocabularyDisabledCommandsIncluded() {
        let enabled = Command(name: "Open Terminal", triggerPhrases: ["open terminal"], isEnabled: true)
        let disabled = Command(name: "Dark Mode", triggerPhrases: ["dark mode"], isEnabled: false)

        let snapshot = builder!.collectVocabulary(
            wakeWords: ["console"],
            commands: [enabled, disabled]
        )

        XCTAssertTrue(snapshot.commandPhrases.contains("open terminal"))
        XCTAssertTrue(snapshot.commandPhrases.contains("dark mode"))
        XCTAssertTrue(snapshot.individualWords.contains("dark"))
        XCTAssertTrue(snapshot.individualWords.contains("mode"))
    }

    // MARK: - Change Detection

    @available(macOS 14.0, *)
    func testRebuildIfNeededSkipsWhenHashUnchanged() async {
        let uniqueWord = "skiptest\(Int.random(in: 10000...99999))"
        let commands = [Command(name: "Skip", triggerPhrases: [uniqueWord])]

        await builder!.rebuildIfNeeded(wakeWords: ["console"], commands: commands)
        XCTAssertNotNil(builder!.compiledModelURL)
        XCTAssertFalse(builder!.isCompiling)

        let urlBefore = builder!.compiledModelURL
        await builder!.rebuildIfNeeded(wakeWords: ["console"], commands: commands)
        XCTAssertFalse(builder!.isCompiling)
        XCTAssertEqual(builder!.compiledModelURL, urlBefore)
    }

    @available(macOS 14.0, *)
    func testRebuildIfNeededRebuildsWhenHashChanges() async {
        let wordA = "hashchangea\(Int.random(in: 10000...99999))"
        let wordB = "hashchangeb\(Int.random(in: 10000...99999))"

        await builder!.rebuildIfNeeded(wakeWords: [wordA], commands: [])
        XCTAssertNotNil(builder!.compiledModelURL)

        await builder!.rebuildIfNeeded(wakeWords: [wordB], commands: [])
        XCTAssertNotNil(builder!.compiledModelURL)
        XCTAssertNil(builder!.lastError)
    }

    @available(macOS 14.0, *)
    func testScheduleRebuildDebouncesCalls() async {
        let word = "debounce\(Int.random(in: 10000...99999))"

        for i in 0..<5 {
            builder!.scheduleRebuild(
                wakeWords: ["\(word)\(i)"],
                commands: []
            )
        }

        try? await Task.sleep(for: .seconds(3))
        XCTAssertFalse(builder!.isCompiling)
        XCTAssertNotNil(builder!.compiledModelURL)
    }

    @available(macOS 14.0, *)
    func testFailedCompilationPreservesPreviousModel() async {
        let word = "preserve\(Int.random(in: 10000...99999))"
        await builder!.rebuildIfNeeded(wakeWords: [word], commands: [])
        let previousURL = builder!.compiledModelURL
        XCTAssertNotNil(previousURL)

        // Rebuild with same vocabulary is a no-op, preserving the URL
        await builder!.rebuildIfNeeded(wakeWords: [word], commands: [])
        XCTAssertEqual(builder!.compiledModelURL, previousURL)
    }
}
