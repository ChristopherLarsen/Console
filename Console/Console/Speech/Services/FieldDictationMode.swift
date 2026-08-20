import Foundation
import AVFoundation

@available(macOS 26.0, *)
@MainActor
final class FieldDictationMode: ListeningMode {

    // MARK: - ListeningMode Conformance

    let modeIdentifier = "fieldDictation"
    let priority: ModePriority = .exclusive
    private(set) var isActive = false

    // MARK: - Callbacks

    var onTextFinalized: ((String) -> Void)?
    var onPauseDetected: (() -> Void)?

    // MARK: - Transcription State

    private var transcriber: SpokenWordTranscriber?
    private var audioStreamTask: Task<Void, Never>?
    private var lastFinalizedLength: Int = 0
    private var accumulatedText: String = ""

    // MARK: - Pause Detection

    private var silenceTimer: Timer?

    // MARK: - ListeningMode Protocol

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        lastFinalizedLength = 0
        accumulatedText = ""

        let story = SpeechStory()
        let newTranscriber = SpokenWordTranscriber(story: story)
        self.transcriber = newTranscriber

        newTranscriber.onFinalizedTextUpdate = { [weak self] in
            self?.handleNewFinalizedText()
        }

        do {
            try await newTranscriber.setUpTranscriber()
        } catch {
            printDebug("[FieldDictation] Failed to set up transcriber: \(error)")
            isActive = false
            return
        }

        guard let audioStream else { return }
        audioStreamTask = Task { [weak self] in
            for await buffer in audioStream {
                guard !Task.isCancelled else { break }
                guard let self, let transcriber = self.transcriber else { continue }
                try? await transcriber.streamAudioToTranscriber(buffer)
            }
        }

        printDebug("[FieldDictation] Activated")
    }

    func deactivate() async {
        audioStreamTask?.cancel()
        audioStreamTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        do {
            try await transcriber?.finishTranscribing()
        } catch {
            printDebug("[FieldDictation] Error finishing transcriber: \(error)")
        }

        transcriber = nil
        isActive = false
        accumulatedText = ""
        lastFinalizedLength = 0
        printDebug("[FieldDictation] Deactivated")
    }

    // MARK: - Transcript Processing

    private func handleNewFinalizedText() {
        guard let transcriber else { return }
        let fullText = String(transcriber.finalizedTranscript.characters)
        guard fullText.count > lastFinalizedLength else { return }

        let delta = String(fullText.dropFirst(lastFinalizedLength))
        lastFinalizedLength = fullText.count
        accumulatedText += delta

        resetSilenceTimer()
    }

    /// Resets the transcript state so stale text is not re-delivered.
    func consume() {
        accumulatedText = ""
        lastFinalizedLength = 0
    }

    // MARK: - Auto-Stop on Speaker Pause

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePauseDetected()
            }
        }
    }

    private func handlePauseDetected() {
        let text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            onTextFinalized?(text)
            consume()
        }
        onPauseDetected?()
        Task { [weak self] in
            guard let self else { return }
            await AudioSessionController.shared.releaseMode(self)
        }
    }
}
