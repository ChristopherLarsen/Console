import XCTest
@testable import Console

@MainActor
final class SilenceGapDetectorTests: XCTestCase {

    // MARK: - 6.1 Cue fires callback on silence

    func testCueFiresOnSilence() async {
        var simulatedLevel: Float = 0.15
        let detector = SilenceGapDetector(audioLevelProvider: { simulatedLevel })

        // Seed with speech-level samples so speechFloor is established
        for _ in 0..<20 {
            detector.seedBuffer(level: 0.15)
        }

        let expectation = XCTestExpectation(description: "Silence callback fires")

        detector.cue {
            expectation.fulfill()
        }

        // Let a few poll ticks run at speech level
        try? await Task.sleep(for: .milliseconds(120))

        // Drop to silence
        simulatedLevel = 0.005

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - 6.2 Cancel discards pending cue

    func testCancelDiscardsPendingCue() async {
        let detector = SilenceGapDetector(audioLevelProvider: { 0.15 })

        for _ in 0..<20 {
            detector.seedBuffer(level: 0.15)
        }

        var callbackFired = false
        detector.cue {
            callbackFired = true
        }

        // Let monitoring start, then cancel before silence
        try? await Task.sleep(for: .milliseconds(100))
        detector.cancel()

        // Wait long enough that the callback would have fired if not cancelled
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(callbackFired, "Callback should not fire after cancel")
    }

    // MARK: - 6.3 Max wait timeout discards cue

    func testMaxWaitTimeoutDiscardsCue() async {
        // Use a short maxWaitDuration so the test completes quickly
        let detector = SilenceGapDetector(
            maxWaitDuration: 0.3,
            audioLevelProvider: { 0.15 }
        )

        for _ in 0..<20 {
            detector.seedBuffer(level: 0.15)
        }

        var callbackFired = false
        detector.cue {
            callbackFired = true
        }

        // Wait longer than maxWaitDuration — speech never drops, cue should be discarded
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(callbackFired, "Callback should not fire after max wait timeout")
    }

    // MARK: - 6.4 Adaptive threshold adjusts with buffer content

    func testAdaptiveThresholdWithLoudSpeaker() async {
        // Loud speaker (RMS ~0.30) needs a higher drop to trigger silence
        var simulatedLevel: Float = 0.30
        let detector = SilenceGapDetector(audioLevelProvider: { simulatedLevel })

        for _ in 0..<20 {
            detector.seedBuffer(level: 0.30)
        }

        let expectation = XCTestExpectation(description: "Silence fires for loud speaker")

        detector.cue {
            expectation.fulfill()
        }

        try? await Task.sleep(for: .milliseconds(120))

        // Level that's below loud threshold (0.30 * 0.25 = 0.075) but above quiet threshold
        simulatedLevel = 0.05

        // Should still fire — 0.05 < 0.075
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testAdaptiveThresholdWithModerateSpeaker() async {
        // Moderate speaker (RMS ~0.10) — threshold = max(0.10 * 0.25, 0.02) = 0.025
        var simulatedLevel: Float = 0.10
        let detector = SilenceGapDetector(audioLevelProvider: { simulatedLevel })

        for _ in 0..<20 {
            detector.seedBuffer(level: 0.10)
        }

        var callbackFired = false
        detector.cue {
            callbackFired = true
        }

        try? await Task.sleep(for: .milliseconds(120))

        // Drop to 0.04 — above threshold (0.025), should NOT fire
        simulatedLevel = 0.04

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(callbackFired, "0.04 is above adaptive threshold 0.025 for moderate speaker")

        // Now drop below threshold
        simulatedLevel = 0.005
        let expectation = XCTestExpectation(description: "Silence fires after full drop")
        // Re-cue since state may still be monitoring
        detector.cue {
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - 6.5 Absolute silence floor for quiet speakers

    func testAbsoluteSilenceFloorForQuietSpeaker() async {
        // Quiet speaker at RMS ~0.04
        // Adaptive threshold alone = 0.04 * 0.25 = 0.01
        // absoluteSilenceFloor = 0.02 overrides → effective threshold = 0.02
        // Dropping to 0.015 (below 0.02) proves the absolute floor is active,
        // because without it the threshold would be 0.01 and 0.015 would NOT trigger.
        var simulatedLevel: Float = 0.04
        let detector = SilenceGapDetector(audioLevelProvider: { simulatedLevel })

        for _ in 0..<20 {
            detector.seedBuffer(level: 0.04)
        }

        let expectation = XCTestExpectation(description: "Absolute floor triggers at 0.015")

        detector.cue {
            expectation.fulfill()
        }

        try? await Task.sleep(for: .milliseconds(120))

        // 0.015 < absoluteSilenceFloor (0.02) — should fire thanks to absolute floor
        simulatedLevel = 0.015

        await fulfillment(of: [expectation], timeout: 2.0)
    }
}
