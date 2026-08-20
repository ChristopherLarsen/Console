import XCTest
@testable import Console

final class SyntheticTranscriptSourceTests: XCTestCase {

    // MARK: - Cumulative Transcript Behavior

    @MainActor
    func testCumulativeTranscriptBuildsCorrectly() async {
        let source = SyntheticTranscriptSource([
            (0.1, "console"),
            (0.2, "open"),
            (0.3, "terminal")
        ])
        source.autoFinalizeDelay = 0.3

        var received: [(String, Bool)] = []
        let finished = expectation(description: "All entries emitted")

        source.startListening { transcript, isFinal in
            received.append((transcript, isFinal))
            if isFinal { finished.fulfill() }
        }

        await fulfillment(of: [finished], timeout: 3.0)

        XCTAssertEqual(received.count, 4, "3 partials + 1 final")
        XCTAssertEqual(received[0].0, "console")
        XCTAssertEqual(received[1].0, "console open")
        XCTAssertEqual(received[2].0, "console open terminal")
        XCTAssertEqual(received[3].0, "console open terminal")
        XCTAssertFalse(received[0].1)
        XCTAssertFalse(received[1].1)
        XCTAssertFalse(received[2].1)
        XCTAssertTrue(received[3].1)
    }

    // MARK: - No Auto-Finalize

    @MainActor
    func testNoAutoFinalizeWhenDelayIsNil() async {
        let source = SyntheticTranscriptSource([
            (0.05, "hello"),
            (0.1, "world")
        ])
        source.autoFinalizeDelay = nil

        var received: [(String, Bool)] = []
        let allPartials = expectation(description: "Partials emitted")

        source.startListening { transcript, isFinal in
            received.append((transcript, isFinal))
            if received.count == 2 { allPartials.fulfill() }
        }

        await fulfillment(of: [allPartials], timeout: 2.0)

        // Wait a bit to confirm no final arrives
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received.count, 2)
        XCTAssertFalse(received.allSatisfy { $0.1 }, "No isFinal should be sent")
        source.stopListening()
    }

    // MARK: - Stop Cancels Emission

    @MainActor
    func testStopCancelsRemainingEntries() async {
        let source = SyntheticTranscriptSource([
            (0.05, "first"),
            (0.5, "second"),
            (1.0, "third")
        ])
        source.autoFinalizeDelay = 0.2

        var received: [String] = []

        source.startListening { transcript, _ in
            received.append(transcript)
        }

        // Let first entry emit, then cancel before second
        try? await Task.sleep(for: .milliseconds(150))
        source.stopListening()

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, "first")
    }

    // MARK: - Timing Accuracy

    @MainActor
    func testEntriesEmitAtCorrectDelays() async {
        let source = SyntheticTranscriptSource([
            (0.1, "a"),
            (0.3, "b")
        ])
        source.autoFinalizeDelay = nil

        var timestamps: [TimeInterval] = []
        let start = Date()
        let done = expectation(description: "Both emitted")

        source.startListening { _, _ in
            timestamps.append(Date().timeIntervalSince(start))
            if timestamps.count == 2 { done.fulfill() }
        }

        await fulfillment(of: [done], timeout: 2.0)

        // Allow 100ms tolerance for scheduling jitter
        XCTAssertEqual(timestamps[0], 0.1, accuracy: 0.1)
        XCTAssertEqual(timestamps[1], 0.3, accuracy: 0.1)
        source.stopListening()
    }

    // MARK: - Codable TranscriptEntry

    func testTranscriptEntryCodableRoundTrip() throws {
        let entries = [
            TranscriptEntry(delay: 1.0, word: "console"),
            TranscriptEntry(delay: 1.2, word: "commands")
        ]

        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([TranscriptEntry].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].delay, 1.0)
        XCTAssertEqual(decoded[0].word, "console")
        XCTAssertEqual(decoded[1].delay, 1.2)
        XCTAssertEqual(decoded[1].word, "commands")
    }

    // MARK: - Single Entry

    @MainActor
    func testSingleEntryWithAutoFinalize() async {
        let source = SyntheticTranscriptSource([(0.05, "hello")])
        source.autoFinalizeDelay = 0.2

        var received: [(String, Bool)] = []
        let finished = expectation(description: "Final received")

        source.startListening { transcript, isFinal in
            received.append((transcript, isFinal))
            if isFinal { finished.fulfill() }
        }

        await fulfillment(of: [finished], timeout: 2.0)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].0, "hello")
        XCTAssertFalse(received[0].1)
        XCTAssertEqual(received[1].0, "hello")
        XCTAssertTrue(received[1].1)
    }
}
