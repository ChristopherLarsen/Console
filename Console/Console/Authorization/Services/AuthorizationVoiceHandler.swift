import Foundation
import AVFoundation
import Speech

/// Listens for spoken authorization or denial words during the authorization dialog.
/// Uses the centralized AudioSessionController as an exclusive ListeningMode.
@Observable
@MainActor
final class AuthorizationVoiceHandler: ListeningMode {

    // MARK: - ListeningMode Conformance

    let modeIdentifier = "authorization"
    let priority: ModePriority = .exclusive
    private(set) var isActive = false

    // MARK: - Private State

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioProcessingTask: Task<Void, Never>?
    private var recognitionRetries = 0
    private let maxRecognitionRetries = 3

    private var approveWords: [String] = []
    private let denyWords = ["cancel", "deny", "stop", "abort", "nevermind"]

    private(set) var isListening = false

    // MARK: - Public API

    func startListening(authorizationWords: [String]) {
        guard !isListening else { return }
        approveWords = authorizationWords.map { $0.lowercased() }
        isListening = true

        Task {
            await AudioSessionController.shared.requestMode(self)
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false

        Task {
            await AudioSessionController.shared.releaseMode(self)
        }
    }

    // MARK: - ListeningMode Lifecycle

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        recognitionRetries = 0

        try? await Task.sleep(for: .milliseconds(200))
        guard isActive else { return }

        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            isActive = false
            isListening = false
            return
        }

        // Buffer loop runs once for the entire mode lifetime
        audioProcessingTask = Task { [weak self] in
            guard let stream = audioStream else { return }
            for await buffer in stream {
                guard !Task.isCancelled else { break }
                self?.recognitionRequest?.append(buffer)
            }
        }

        startRecognitionTask()
    }

    private func startRecognitionTask() {
        guard isActive, let speechRecognizer, speechRecognizer.isAvailable else { return }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }

                if let result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    self.evaluateTranscription(text)
                }

                if error != nil {
                    self.handleRecognitionError()
                }
            }
        }
    }

    private func handleRecognitionError() {
        guard isActive else { return }

        if recognitionRetries < maxRecognitionRetries {
            recognitionRetries += 1
            startRecognitionTask()
        } else {
            stopListening()
        }
    }

    func deactivate() async {
        isActive = false
        audioProcessingTask?.cancel()
        audioProcessingTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        speechRecognizer = nil
    }

    // MARK: - Keyword Matching

    private func evaluateTranscription(_ text: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .punctuationCharacters)
            .joined()

        if approveWords.contains(where: { normalized.contains($0) }) {
            stopListening()
            AuthorizationManager.shared.approve()
        } else if denyWords.contains(where: { normalized.contains($0) }) {
            stopListening()
            AuthorizationManager.shared.deny()
        }
    }
}
