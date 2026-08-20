import Foundation
import SwiftUI

@Observable
@MainActor
final class AutoSendController {

    // MARK: - Public State

    /// Progress of the auto-send countdown (0.0 = not started, 1.0 = about to send).
    private(set) var countdownProgress: Double = 0.0

    /// Whether the countdown timer is currently running.
    var isCountdownActive: Bool { countdownTimer != nil }

    /// Called when the countdown completes and the message should be sent.
    var onAutoSend: (() -> Void)?

    // MARK: - Configuration

    private var countdownDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "speechCountdownDuration")
        return stored >= 1.0 ? stored : 2.0
    }
    private let tickInterval: TimeInterval = 1.0 / 30.0 // ~30 fps for smooth progress

    // MARK: - Audio Baseline

    /// Adaptive baseline RMS computed from quiet periods (exponential moving average).
    private var baselineRMS: Float = 0.01
    private let baselineSmoothing: Float = 0.05
    private let baselineFloor: Float = 0.005
    private let speakingMultiplier: Float = 2.0

    // MARK: - Filler Detection

    private let fillerUtterances: Set<String> = [
        "ah", "uh", "um", "mm", "mmm", "hmm", "hm",
        "huh", "eh", "oh", "er", "erm", "mhm", "uhh",
        "ahh", "umm", "uhm"
    ]

    // MARK: - Private Timer State

    private var countdownTimer: Timer?
    private var countdownStartDate: Date?

    // MARK: - Public API

    /// Start the 2-second countdown. No-op if already active.
    func startCountdown() {
        guard countdownTimer == nil else { return }
        countdownStartDate = Date()
        countdownProgress = 0.0

        countdownTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    /// Cancel the countdown and reset progress.
    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownStartDate = nil
        countdownProgress = 0.0
    }

    /// Full reset (e.g. when speech is deactivated).
    func reset() {
        cancelCountdown()
        baselineRMS = 0.01
    }

    /// Returns true if the given text is a filler utterance that should be discarded.
    func isFillerUtterance(_ text: String) -> Bool {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter }
        return fillerUtterances.contains(cleaned)
    }

    /// Returns true if the current RMS level is below the adaptive speaking threshold.
    func shouldTreatAsLowEnergy(currentRMS: Float) -> Bool {
        currentRMS < baselineRMS * speakingMultiplier
    }

    /// Update the adaptive baseline with a new RMS sample observed during a quiet period
    /// (i.e. when volatile transcript is empty and no speech is detected).
    func updateBaseline(quietRMS: Float) {
        baselineRMS = baselineRMS * (1.0 - baselineSmoothing) + quietRMS * baselineSmoothing
        baselineRMS = max(baselineRMS, baselineFloor)
    }

    // MARK: - Private

    private func tick() {
        guard let start = countdownStartDate else {
            cancelCountdown()
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let progress = min(elapsed / countdownDuration, 1.0)
        countdownProgress = progress

        if progress >= 1.0 {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownStartDate = nil
            onAutoSend?()
            // Reset progress after send so the bar returns to grey.
            countdownProgress = 0.0
        }
    }
}
