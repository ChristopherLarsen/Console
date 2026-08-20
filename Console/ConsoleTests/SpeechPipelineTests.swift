import XCTest
@testable import Console

final class CommandListeningModeTests: XCTestCase {

    // MARK: - Test 1: Wake word + built-in command

    @MainActor
    func testWakeWordDetection_ConsoleCommands() async {
        let source = SyntheticTranscriptSource([
            (0.5, "console"),
            (0.7, "commands")
        ])
        source.autoFinalizeDelay = 1.5

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        let wakeWordExpectation = expectation(description: "Wake word detected")
        let commandExpectation = expectation(description: "Command transcribed")

        var detectedWakeWord: String?
        var transcribedCommand: String?

        mode.onWakeWordDetected = { wakeWord in
            detectedWakeWord = wakeWord
            wakeWordExpectation.fulfill()
        }

        mode.onCommandTranscribed = { command in
            transcribedCommand = command
            commandExpectation.fulfill()
        }

        await mode.activate(audioStream: nil)

        await fulfillment(of: [wakeWordExpectation, commandExpectation], timeout: 6.0)

        XCTAssertEqual(detectedWakeWord, "console")
        XCTAssertEqual(transcribedCommand, "commands")
        await mode.deactivate()
    }

    // MARK: - Test 2: No wake word match

    @MainActor
    func testNoWakeWord_PopcornTime() async {
        let source = SyntheticTranscriptSource([
            (0.5, "popcorn"),
            (0.8, "time")
        ])
        source.autoFinalizeDelay = 0.5

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        let wakeWordExpectation = expectation(description: "No wake word")
        wakeWordExpectation.isInverted = true

        let commandExpectation = expectation(description: "No command")
        commandExpectation.isInverted = true

        mode.onWakeWordDetected = { _ in
            wakeWordExpectation.fulfill()
        }

        mode.onCommandTranscribed = { _ in
            commandExpectation.fulfill()
        }

        await mode.activate(audioStream: nil)

        await fulfillment(of: [wakeWordExpectation, commandExpectation], timeout: 3.0)

        XCTAssertEqual(mode.phase, .idle)
        await mode.deactivate()
    }

    // MARK: - Test 3: Wake word triggers but command is unrecognized

    @MainActor
    func testWakeWordNoMatch_ConsoleLeviathan() async {
        let source = SyntheticTranscriptSource([
            (0.5, "console"),
            (0.7, "leviathan")
        ])
        source.autoFinalizeDelay = 1.5

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        let wakeWordExpectation = expectation(description: "Wake word detected")
        let commandExpectation = expectation(description: "Command transcribed")

        var detectedWakeWord: String?
        var transcribedCommand: String?

        mode.onWakeWordDetected = { wakeWord in
            detectedWakeWord = wakeWord
            wakeWordExpectation.fulfill()
        }

        mode.onCommandTranscribed = { command in
            transcribedCommand = command
            commandExpectation.fulfill()
        }

        await mode.activate(audioStream: nil)

        await fulfillment(of: [wakeWordExpectation, commandExpectation], timeout: 6.0)

        XCTAssertEqual(detectedWakeWord, "console")
        XCTAssertEqual(transcribedCommand, "leviathan")
        await mode.deactivate()
    }

    // MARK: - Test 4: Activate and deactivate lifecycle

    @MainActor
    func testActivateAndDeactivate() async {
        let mode = CommandListeningMode(transcriptSource: SyntheticTranscriptSource([]))
        mode.updateWakeWords(["console"])

        XCTAssertFalse(mode.isActive)
        XCTAssertEqual(mode.phase, .idle)

        await mode.activate(audioStream: nil)

        XCTAssertTrue(mode.isActive)

        await mode.deactivate()

        XCTAssertFalse(mode.isActive)
        XCTAssertEqual(mode.phase, .idle)
        XCTAssertNil(mode.detectedWord)
        XCTAssertTrue(mode.transcribedText.isEmpty)
        XCTAssertTrue(mode.fullTranscript.isEmpty)
    }

    // MARK: - Test 5: "console wave" should produce command text "wave"

    @MainActor
    func testConsoleWave_ProducesCommandWave() async {
        let source = SyntheticTranscriptSource([
            (0.5, "console"),
            (0.7, "wave")
        ])
        source.autoFinalizeDelay = 1.5

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        let wakeWordExpectation = expectation(description: "Wake word detected")
        let commandExpectation = expectation(description: "Command transcribed")

        var detectedWakeWord: String?
        var transcribedCommand: String?

        mode.onWakeWordDetected = { wakeWord in
            detectedWakeWord = wakeWord
            wakeWordExpectation.fulfill()
        }

        mode.onCommandTranscribed = { command in
            transcribedCommand = command
            commandExpectation.fulfill()
        }

        await mode.activate(audioStream: nil)

        await fulfillment(of: [wakeWordExpectation, commandExpectation], timeout: 6.0)

        XCTAssertEqual(detectedWakeWord, "console")
        XCTAssertEqual(transcribedCommand, "wave", "'console wave' should produce command 'wave'")
        await mode.deactivate()
    }

    // MARK: - Test 6: Session restart after isFinal in idle phase

    @MainActor
    func testSessionRestart_DetectsSecondWakeWord() async {
        let source = SyntheticTranscriptSource([
            (0.1, "hello"),
            (0.2, "world")
        ])
        source.autoFinalizeDelay = 0.3

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        await mode.activate(audioStream: nil)

        // Wait for the first session to finalize (no wake word)
        try? await Task.sleep(for: .milliseconds(800))

        // After isFinal in idle phase, fullTranscript should be reset
        XCTAssertEqual(mode.phase, .idle)
        XCTAssertTrue(mode.fullTranscript.isEmpty)

        // Now inject a second transcript with a wake word directly
        mode.handleTranscriptUpdate("console open safari", isFinal: false)

        XCTAssertEqual(mode.phase, .capturingCommand)
        XCTAssertEqual(mode.detectedWord, "console")

        // Finalize the command
        mode.handleTranscriptUpdate("console open safari", isFinal: true)

        XCTAssertEqual(mode.phase, .idle)
        await mode.deactivate()
    }
}
