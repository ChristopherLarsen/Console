import XCTest
@testable import Console

/// H16-F01/F02/F04 — wake word detection and command extraction.
final class WakeWordCaptureTests: XCTestCase {

    @MainActor
    private func makeActivatedMode(
        wakeWords: [String],
        allWakeWords: [String]? = nil
    ) async -> CommandListeningMode {
        let mode = CommandListeningMode(transcriptSource: SyntheticTranscriptSource([]))
        mode.updateWakeWords(wakeWords, allWakeWords: allWakeWords ?? wakeWords)
        await mode.activate(audioStream: nil)
        return mode
    }

    // MARK: - H16-F01: multi-word trigger words must be detected

    @MainActor
    func testMultiWordTriggerWordIsDetected() async {
        let mode = await makeActivatedMode(wakeWords: ["hey console"])

        let detected = expectation(description: "wake word detected")
        var detectedWord: String?
        mode.onWakeWordDetected = {
            detectedWord = $0
            detected.fulfill()
        }

        mode.handleTranscriptUpdate("hey console open terminal", isFinal: false)
        await fulfillment(of: [detected], timeout: 2.0)
        XCTAssertEqual(detectedWord, "hey console")
        await mode.deactivate()
    }

    // MARK: - H16-F02: punctuated SR tokens must still match

    @MainActor
    func testPunctuatedWakeWordTokenIsDetected() async {
        let mode = await makeActivatedMode(wakeWords: ["console"])

        let detected = expectation(description: "wake word detected")
        mode.onWakeWordDetected = { _ in detected.fulfill() }

        mode.handleTranscriptUpdate("Console.", isFinal: false)
        await fulfillment(of: [detected], timeout: 2.0)
        await mode.deactivate()
    }

    @MainActor
    func testPunctuatedTokenExtractsCommand() async {
        let mode = await makeActivatedMode(wakeWords: ["console"])

        let command = expectation(description: "command transcribed")
        var commandText: String?
        mode.onCommandTranscribed = {
            commandText = $0
            command.fulfill()
        }

        // Detection arms on "console."; the finalized transcript keeps the
        // punctuation. Extraction must yield the command, not drop it.
        mode.handleTranscriptUpdate("console.", isFinal: false)
        mode.handleTranscriptUpdate("console. open terminal", isFinal: true)
        await fulfillment(of: [command], timeout: 2.0)
        XCTAssertEqual(commandText, "open terminal")
        await mode.deactivate()
    }

    // MARK: - H16-F04: prefix fallback must not truncate a revised transcript

    @MainActor
    func testRevisedTranscriptWithoutPrefixIsNotTruncated() async {
        let mode = await makeActivatedMode(wakeWords: ["console"])

        let command = expectation(description: "command transcribed")
        var commandText: String?
        mode.onCommandTranscribed = {
            commandText = $0
            command.fulfill()
        }

        // SR revised the wake word away: the new hypothesis no longer starts
        // with "console", so the prefix-count fallback must not apply.
        mode.handleTranscriptUpdate("console", isFinal: false)
        mode.handleTranscriptUpdate("open the terminal", isFinal: true)
        await fulfillment(of: [command], timeout: 2.0)
        XCTAssertEqual(commandText, "open the terminal")
        await mode.deactivate()
    }

    @MainActor
    func testPrefixStillPresentStillUsesFallback() async {
        let mode = await makeActivatedMode(wakeWords: ["zzzq"])

        let command = expectation(description: "command transcribed")
        var commandText: String?
        mode.onCommandTranscribed = {
            commandText = $0
            command.fulfill()
        }

        // The stripper cannot find "zzzq" (punctuated), but the snapshot prefix
        // still leads the transcript, so the fallback extracts after it.
        mode.handleTranscriptUpdate("zzzq", isFinal: false)
        mode.handleTranscriptUpdate("zzzq. open terminal", isFinal: true)
        await fulfillment(of: [command], timeout: 2.0)
        XCTAssertEqual(commandText, "open terminal")
        await mode.deactivate()
    }

    // MARK: - H16-F03 companion: words absent from the strip list are not stripped

    @MainActor
    func testWordOutsideStripListIsKeptInCommand() async {
        // allWakeWords only carries enabled words now; a disabled word that is
        // not in the list must not wipe the command text.
        let mode = await makeActivatedMode(
            wakeWords: ["console"],
            allWakeWords: ["console"]
        )

        let command = expectation(description: "command transcribed")
        var commandText: String?
        mode.onCommandTranscribed = {
            commandText = $0
            command.fulfill()
        }

        mode.handleTranscriptUpdate("console open terminal", isFinal: false)
        mode.handleTranscriptUpdate("console open terminal", isFinal: true)
        await fulfillment(of: [command], timeout: 2.0)
        XCTAssertEqual(commandText, "open terminal")
        await mode.deactivate()
    }
}