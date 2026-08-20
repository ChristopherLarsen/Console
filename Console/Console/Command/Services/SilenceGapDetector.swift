import Foundation

/// Monitors audio RMS levels and fires a callback when a speech-to-silence transition is confirmed.
@MainActor
final class SilenceGapDetector {

    // MARK: - Configuration

    let pollInterval: TimeInterval = 0.05
    let rollingWindowSize: Int = 20
    let noiseFloor: Float = 0.01
    let dropRatio: Float = 0.25
    private(set) var confirmationDuration: TimeInterval = 0.15
    let absoluteSilenceFloor: Float = 0.02
    private(set) var maxWaitDuration: TimeInterval = 3.0

    // Injectable for testing; defaults to live audio level
    private let audioLevelProvider: () -> Float

    // MARK: - Rolling Buffer

    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var sampleCount: Int = 0

    // MARK: - State

    private enum DetectorState {
        case idle
        case monitoring
        case confirming(since: Date)
    }

    private var state: DetectorState = .idle
    private var onSilenceDetected: (() -> Void)?
    private var pollTask: Task<Void, Never>?

    // MARK: - Computed Thresholds

    private var speechFloor: Float {
        let validSamples = buffer[0..<sampleCount].filter { $0 > noiseFloor }
        guard !validSamples.isEmpty else { return noiseFloor }
        return validSamples.reduce(0, +) / Float(validSamples.count)
    }

    private var currentSilenceThreshold: Float {
        max(speechFloor * dropRatio, absoluteSilenceFloor)
    }

    // MARK: - Init

    init(
        maxWaitDuration: TimeInterval? = nil,
        confirmationDuration: TimeInterval? = nil,
        audioLevelProvider: (() -> Float)? = nil
    ) {
        if let maxWaitDuration { self.maxWaitDuration = maxWaitDuration }
        if let confirmationDuration { self.confirmationDuration = confirmationDuration }
        self.audioLevelProvider = audioLevelProvider ?? { AudioSessionController.shared.currentAudioLevel }
        buffer = [Float](repeating: 0.0, count: rollingWindowSize)
    }

    // MARK: - Public API

    func cue(onSilenceDetected: @escaping () -> Void) {
        cancel()
        self.onSilenceDetected = onSilenceDetected
        state = .monitoring
        #if DEBUG
        printDebug("[SilenceGap] Cue started — speechFloor: \(speechFloor)")
        #endif
        startPolling()
    }

    func cancel() {
        #if DEBUG
        if case .monitoring = state { printDebug("[SilenceGap] Cue discarded — cancelled while monitoring") }
        if case .confirming = state { printDebug("[SilenceGap] Cue discarded — cancelled while confirming") }
        #endif
        pollTask?.cancel()
        pollTask = nil
        onSilenceDetected = nil
        state = .idle
    }

    /// Feeds RMS values into the rolling buffer while idle, so speechFloor is accurate when cue() fires.
    func seedBuffer(level: Float) {
        guard case .idle = state else { return }
        pushSample(level)
    }

    // MARK: - Buffer

    private func pushSample(_ level: Float) {
        buffer[writeIndex] = level
        writeIndex = (writeIndex + 1) % rollingWindowSize
        if sampleCount < rollingWindowSize { sampleCount += 1 }
    }

    // MARK: - Poll Loop

    private func startPolling() {
        let startTime = Date()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if Date().timeIntervalSince(startTime) >= self.maxWaitDuration {
                    #if DEBUG
                    printDebug("[SilenceGap] Max wait exceeded, discarding cue")
                    #endif
                    self.cancel()
                    return
                }

                let level = self.audioLevelProvider()
                self.pushSample(level)
                let threshold = self.currentSilenceThreshold

                switch self.state {
                case .monitoring:
                    if level <= threshold {
                        self.state = .confirming(since: Date())
                    }

                case .confirming(let since):
                    if level > threshold {
                        self.state = .monitoring
                    } else if Date().timeIntervalSince(since) >= self.confirmationDuration {
                        #if DEBUG
                        printDebug("[SilenceGap] Silence confirmed — floor: \(self.speechFloor), threshold: \(threshold)")
                        #endif
                        self.fireCue()
                        return
                    }

                case .idle:
                    return
                }

                try? await Task.sleep(for: .milliseconds(Int(self.pollInterval * 1000)))
            }
        }
    }

    // MARK: - Fire

    private func fireCue() {
        let callback = onSilenceDetected
        onSilenceDetected = nil
        state = .idle
        pollTask?.cancel()
        pollTask = nil
        callback?()
    }
}
