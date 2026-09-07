import Foundation
import AVFoundation
import Speech

enum PipelinePhase {
    case idle
    case capturingCommand
}

@Observable
@MainActor
final class CommandListeningMode: ListeningMode {

    // MARK: - ListeningMode Conformance

    let modeIdentifier = "command"
    let priority: ModePriority = .primary
    private(set) var isActive = false

    // MARK: - Public State

    private(set) var phase: PipelinePhase = .idle
    private(set) var detectedWord: String?
    private(set) var transcribedText: String = ""
    private(set) var fullTranscript: String = ""
    private(set) var volatileText: String = ""

    var listeningState: ListeningState {
        guard isActive else { return .off }
        switch phase {
        case .idle: return .passive
        case .capturingCommand: return .commandListening
        }
    }

    // MARK: - Callbacks

    var onWakeWordDetected: ((_ wakeWord: String) -> Void)?
    var onCommandTranscribed: ((_ commandText: String) -> Void)?
    var onCommandCancelled: (() -> Void)?
    var onRawAndStrippedText: ((_ raw: String, _ stripped: String) -> Void)?
    /// Called during capturingCommand on each transcript update to attempt an eager match.
    /// Returns true if a match was found and the command was executed.
    var onEagerMatchAttempt: ((_ commandText: String) -> Bool)?

    // MARK: - Configuration

    private var activeWakeWords: [String] = []
    private var allConfiguredWakeWords: [String] = []

    // MARK: - Wake Word Detection State

    private var hasDetectedInCurrentSession = false

    // MARK: - Command Capture State

    private var commandCaptureStartTime: Date?
    var hasReceivedPostWakeWordSpeech = false
    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?
    private var stabilityTimer: Timer?
    private var lastTranscriptSnapshot: String = ""
    private var wakeWordTranscriptPrefix: String = ""
    private var lastSpeechTime: Date = Date()
    private var lastAudioLevel: Float = 0.0
    private var isCurrentlySilent: Bool = false

    private let maxCommandDuration: TimeInterval = 10.0
    private let silenceThreshold: TimeInterval = 0.5
    private let silenceVolumeThreshold: Float = 0.05
    private let minCommandDuration: TimeInterval = 0.01
    private let transcriptStabilityThreshold: TimeInterval = 0.75

    // MARK: - Audio Level Observation

    private var audioLevelTask: Task<Void, Never>?
    private let silenceGapDetector = SilenceGapDetector()
    private var suppressWakeWordCue = false

    // MARK: - Speech Recognition

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioStreamTask: Task<Void, Never>?
    private var audioStream: AsyncStream<AVAudioPCMBuffer>?
    private var taskGeneration = 0
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private var restartTask: Task<Void, Never>?

    // Allows injecting a synthetic transcript source for testing
    private var transcriptSource: TranscriptSource?

    // MARK: - Transcript

    private var currentWakeWord: String?

    // MARK: - Stop Reason

    private enum StopReason {
        case silenceDetected
        case maxDurationReached
        case recognitionFinal
        case recognitionError
    }

    // MARK: - Init

    init(transcriptSource: TranscriptSource? = nil) {
        self.transcriptSource = transcriptSource
    }

    // MARK: - Public API

    func updateWakeWords(_ words: [String], allWakeWords: [String] = []) {
        activeWakeWords = words.map { $0.lowercased() }
        allConfiguredWakeWords = allWakeWords
    }

    // MARK: - ListeningMode Protocol

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        phase = .idle
        self.audioStream = audioStream
        consecutiveFailures = 0

        if let transcriptSource {
            transcriptSource.startListening { [weak self] transcript, isFinal in
                Task { @MainActor [weak self] in
                    self?.handleTranscriptUpdate(transcript, isFinal: isFinal)
                }
            }
        } else {
            startAudioLevelObservation()
            startRecognitionSession()
            startBufferForwarding()
        }
        printDebug("[CommandMode] Activated")
    }

    func deactivate() async {
        let wasCapturing = phase == .capturingCommand
        cancelCommandTimers()
        silenceGapDetector.cancel()
        transcriptSource?.stopListening()
        stopRecognition()
        audioStreamTask?.cancel()
        audioStreamTask = nil
        restartTask?.cancel()
        restartTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioStream = nil
        resetState()
        if wasCapturing { onCommandCancelled?() }
        printDebug("[CommandMode] Deactivated")
    }

    // MARK: - Transcript Processing

    func handleTranscriptUpdate(_ transcript: String, isFinal: Bool) {
        guard isActive else { return }
        fullTranscript = transcript
        volatileText = isFinal ? "" : transcript

        switch phase {
        case .idle:
            checkForWakeWord(in: transcript.lowercased())

        case .capturingCommand:
            transcribedText = transcript
            hasReceivedPostWakeWordSpeech = true
            lastSpeechTime = Date()

            if transcript != lastTranscriptSnapshot {
                lastTranscriptSnapshot = transcript
                resetStabilityTimer()

                // Eager matching: extract command text and try to match immediately
                if let onEagerMatchAttempt {
                    let commandText = extractCommandText(from: transcript)
                    if !commandText.isEmpty, onEagerMatchAttempt(commandText) {
                        finalizeCommand(reason: .recognitionFinal)
                        return
                    }
                }
            }
        }

        if isFinal {
            if phase == .capturingCommand {
                finalizeCommand(reason: .recognitionFinal)
            } else {
                restartTranscriptSession()
            }
        }
    }

    func handleSessionError() {
        if phase == .capturingCommand {
            if hasReceivedPostWakeWordSpeech {
                finalizeCommand(reason: .recognitionError)
            } else {
                cancelCurrentRecording()
            }
        }
    }

    // MARK: - Wake Word Detection

    private func checkForWakeWord(in transcript: String) {
        guard !hasDetectedInCurrentSession else { return }

        let tokens = transcript
            .split(separator: " ")
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }

        for wakeWord in activeWakeWords {
            if Self.containsTokenSequence(tokens, wakeWordParts(wakeWord)) {
                hasDetectedInCurrentSession = true
                detectedWord = wakeWord
                currentWakeWord = wakeWord
                UserDefaults.standard.set(wakeWord, forKey: "lastUsedTriggerWord")

                suppressWakeWordCue = false
                silenceGapDetector.cue { [weak self] in
                    guard let self, !self.suppressWakeWordCue else { return }
                    SoundFeedbackService.shared.play(.wakeWordDetected)
                }
                onWakeWordDetected?(wakeWord)

                phase = .capturingCommand
                commandCaptureStartTime = Date()
                hasReceivedPostWakeWordSpeech = false
                lastSpeechTime = Date()
                lastAudioLevel = 0.0
                isCurrentlySilent = false
                lastTranscriptSnapshot = fullTranscript
                wakeWordTranscriptPrefix = fullTranscript
                startMaxDurationTimer()
                return
            }
        }
    }

    private func wakeWordParts(_ wakeWord: String) -> [String] {
        wakeWord.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func containsTokenSequence(_ tokens: [String], _ parts: [String]) -> Bool {
        guard !parts.isEmpty, parts.count <= tokens.count else { return false }
        for start in 0...(tokens.count - parts.count) {
            if Array(tokens[start..<(start + parts.count)]) == parts { return true }
        }
        return false
    }

    // MARK: - Command Finalization

    private func finalizeCommand(reason: StopReason) {
        guard phase == .capturingCommand else { return }

        cancelCommandTimers()
        suppressWakeWordCue = true
        silenceGapDetector.cancel()

        let rawText = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        phase = .idle
        commandCaptureStartTime = nil
        transcribedText = ""
        lastAudioLevel = 0.0
        isCurrentlySilent = false

        restartTranscriptSession()

        guard !rawText.isEmpty else {
            VisualFeedbackService.shared.show(.warning("No command detected"))
            onCommandCancelled?()
            return
        }

        let commandText: String
        if let wakeWord = currentWakeWord {
            let stripped = WakeWordStripper.stripWakeWord(
                from: rawText,
                detectedWakeWord: wakeWord,
                allWakeWords: allConfiguredWakeWords
            )
            // If the wake word was revised away by speech recognition,
            // fall back to extracting new text added after the wake word snapshot —
            // but only while the snapshot prefix still leads the transcript.
            if stripped == rawText, let fallback = postWakeWordFallbackText(from: rawText) {
                commandText = fallback
            } else {
                commandText = stripped
            }
        } else {
            commandText = rawText
        }

        currentWakeWord = nil

        guard !commandText.isEmpty else {
            VisualFeedbackService.shared.show(.warning("No command detected"))
            onCommandCancelled?()
            return
        }

        onRawAndStrippedText?(rawText, commandText)
        onCommandTranscribed?(commandText)
    }

    func cancelCurrentRecording() {
        guard phase == .capturingCommand else { return }
        cancelCommandTimers()
        suppressWakeWordCue = true
        silenceGapDetector.cancel()
        phase = .idle
        commandCaptureStartTime = nil
        transcribedText = ""
        lastAudioLevel = 0.0
        isCurrentlySilent = false
        currentWakeWord = nil
        wakeWordTranscriptPrefix = ""
        onCommandCancelled?()
        restartTranscriptSession()
    }

    /// Extracts the command portion from the current transcript by stripping the wake word.
    private func extractCommandText(from transcript: String) -> String {
        let rawText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty, let wakeWord = currentWakeWord else { return "" }

        let stripped = WakeWordStripper.stripWakeWord(
            from: rawText,
            detectedWakeWord: wakeWord,
            allWakeWords: allConfiguredWakeWords
        )
        // Fallback if wake word was revised away
        if stripped == rawText, let fallback = postWakeWordFallbackText(from: rawText) {
            return fallback
        }
        return stripped
    }

    /// When speech recognition revised the wake word away, the snapshot prefix
    /// may no longer lead the transcript; only skip the prefix word count while
    /// the prefix is still present (ignoring case and punctuation), otherwise
    /// real command words would be truncated.
    private func postWakeWordFallbackText(from rawText: String) -> String? {
        guard !wakeWordTranscriptPrefix.isEmpty else { return nil }

        func normalized(_ word: Substring) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        let prefixWords = wakeWordTranscriptPrefix.split(separator: " ").map(normalized)
        let allWords = rawText.split(separator: " ").map { String($0) }
        guard prefixWords.count < allWords.count else { return nil }
        let leading = allWords.prefix(prefixWords.count).map { normalized(Substring($0)) }
        guard leading == prefixWords else { return nil }

        return WakeWordStripper.stripLeadingFillers(Array(allWords[prefixWords.count...]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resets wake word state and restarts the speech recognition session.
    func restartTranscriptSession() {
        silenceGapDetector.cancel()
        hasDetectedInCurrentSession = false
        fullTranscript = ""
        volatileText = ""
        if transcriptSource == nil {
            stopRecognitionTask()
            startRecognitionSession()
        }
    }

    // MARK: - Speech Recognition Session

    private func startRecognitionSession() {
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }
        if #available(macOS 14.0, *) {
            if let modelURL = CustomLanguageModelBuilder.shared?.compiledModelURL {
                request.customizedLanguageModel = .init(languageModel: modelURL)
            }
        }
        self.recognitionRequest = request

        taskGeneration += 1
        let expectedGeneration = taskGeneration

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.taskGeneration == expectedGeneration else { return }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kLSRErrorDomain" && nsError.code == 201 {
                        printDebug("[CommandMode] Fatal recognition error: \(nsError.localizedDescription)")
                        VisualFeedbackService.shared.show(.warning("Speech recognition unavailable"))
                        self.onCommandCancelled?()
                        await AudioSessionController.shared.releaseMode(self)
                        return
                    }
                }

                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.consecutiveFailures = 0
                    self.handleTranscriptUpdate(transcript, isFinal: result.isFinal)
                }

                if let error, result?.isFinal != true {
                    let isCancellation = (error as NSError).code == 216
                        || error.localizedDescription.contains("canceled")
                    guard !isCancellation else { return }

                    self.handleSessionError()
                    self.handleRecognitionEnd()
                }
            }
        }
    }

    private func startBufferForwarding() {
        guard let audioStream else { return }
        audioStreamTask = Task { [weak self] in
            for await buffer in audioStream {
                guard !Task.isCancelled else { break }
                self?.recognitionRequest?.append(buffer)
            }
        }
    }

    private func stopRecognitionTask() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func stopRecognition() {
        stopRecognitionTask()
        speechRecognizer = nil
    }

    private func handleRecognitionEnd() {
        stopRecognitionTask()

        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            printDebug("[CommandMode] Max consecutive failures, releasing mode")
            VisualFeedbackService.shared.show(.warning("Speech recognition unavailable"))
            onCommandCancelled?()
            Task { [weak self] in
                guard let self else { return }
                await AudioSessionController.shared.releaseMode(self)
            }
            return
        }

        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.startRecognitionSession()
        }
    }

    // MARK: - Audio Level / Silence Detection

    private func startAudioLevelObservation() {
        audioLevelTask?.cancel()
        audioLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = AudioSessionController.shared.currentAudioLevel
                if self.phase == .capturingCommand {
                    self.updateAudioLevel(level)
                }
                self.silenceGapDetector.seedBuffer(level: level)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func updateAudioLevel(_ level: Float) {
        lastAudioLevel = level

        let wasSilent = isCurrentlySilent
        isCurrentlySilent = level < silenceVolumeThreshold

        if !isCurrentlySilent {
            lastSpeechTime = Date()
        }

        if isCurrentlySilent && !wasSilent {
            startSilenceTimer()
        } else if !isCurrentlySilent && wasSilent {
            cancelSilenceTimer()
        }
    }

    // MARK: - Silence Timer

    private func startSilenceTimer() {
        guard hasReceivedPostWakeWordSpeech else { return }
        guard let start = commandCaptureStartTime else { return }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed < minCommandDuration {
            let remaining = minCommandDuration - elapsed + 0.05
            silenceTimer?.invalidate()
            silenceTimer = Timer.scheduledTimer(
                withTimeInterval: remaining,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .capturingCommand, self.isCurrentlySilent else { return }
                    self.startSilenceTimer()
                }
            }
            return
        }

        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceThreshold,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finalizeCommand(reason: .silenceDetected)
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Stability Timer

    private func resetStabilityTimer() {
        stabilityTimer?.invalidate()
        guard hasReceivedPostWakeWordSpeech,
              let start = commandCaptureStartTime else { return }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed < minCommandDuration {
            let remaining = minCommandDuration - elapsed + 0.05
            stabilityTimer = Timer.scheduledTimer(
                withTimeInterval: remaining,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .capturingCommand else { return }
                    self.resetStabilityTimer()
                }
            }
            return
        }

        stabilityTimer = Timer.scheduledTimer(
            withTimeInterval: transcriptStabilityThreshold,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finalizeCommand(reason: .silenceDetected)
            }
        }
    }

    private func cancelStabilityTimer() {
        stabilityTimer?.invalidate()
        stabilityTimer = nil
    }

    // MARK: - Max Duration Timer

    private func startMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(
            withTimeInterval: maxCommandDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hasReceivedPostWakeWordSpeech {
                    self.finalizeCommand(reason: .maxDurationReached)
                } else {
                    self.cancelCurrentRecording()
                }
            }
        }
    }

    private func cancelMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    // MARK: - Timer Cleanup

    private func cancelCommandTimers() {
        cancelSilenceTimer()
        cancelStabilityTimer()
        cancelMaxDurationTimer()
    }

    // MARK: - State Reset

    private func resetState() {
        silenceGapDetector.cancel()
        isActive = false
        phase = .idle
        detectedWord = nil
        transcribedText = ""
        fullTranscript = ""
        volatileText = ""
        hasDetectedInCurrentSession = false
        commandCaptureStartTime = nil
        hasReceivedPostWakeWordSpeech = false
        lastAudioLevel = 0.0
        isCurrentlySilent = false
        currentWakeWord = nil
        wakeWordTranscriptPrefix = ""
    }
}
