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

    private(set) var isListening = false
    private var hasRequestedMode = false
    private var modeGeneration = 0

    // MARK: - Public API

    func startListening(authorizationWords: [String]) {
        guard !isListening else { return }
        approveWords = authorizationWords.map { $0.lowercased() }
        isListening = true
        hasRequestedMode = true
        modeGeneration += 1

        Task {
            await AudioSessionController.shared.requestMode(self)
        }
    }

    func stopListening() {
        guard hasRequestedMode else { return }
        hasRequestedMode = false
        isListening = false

        Task {
            await AudioSessionController.shared.releaseMode(self)
        }
    }

    // MARK: - ListeningMode Lifecycle

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        recognitionRetries = 0
        let generation = modeGeneration

        try? await Task.sleep(for: .milliseconds(200))
        guard isActive else {
            // Cancelled during preroll: the pending releaseMode no-oped because the
            // mode had not been registered yet; release once requestMode registers us.
            scheduleDeferredRelease(generation: generation)
            return
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            isActive = false
            isListening = false
            hasRequestedMode = false
            scheduleDeferredRelease(generation: generation)
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

    /// Releases the exclusive audio mode on activation failure. A later start
    /// bumps modeGeneration, so stale releases from an aborted activation no-op.
    private func scheduleDeferredRelease(generation: Int) {
        Task { [weak self] in
            guard let self, self.modeGeneration == generation else { return }
            await AudioSessionController.shared.releaseMode(self)
        }
    }

    // MARK: - Keyword Matching

    private func evaluateTranscription(_ text: String) {
        switch AuthorizationVoiceDecision.evaluate(forTranscript: text, approveWords: approveWords) {
        case .approve:
            stopListening()
            AuthorizationManager.shared.approve()
        case .deny:
            stopListening()
            AuthorizationManager.shared.deny()
        case .none:
            break
        }
    }

}

/// Pure decision logic for spoken authorization matching, kept outside the
/// MainActor-isolated handler so it is unit-testable.
enum AuthorizationVoiceDecision {
    case approve
    case deny
    case none

    /// Whole-token matching so "okay wait" or "going" cannot approve via the
    /// "ok"/"go" substring. Deny words win over approval, and a negated
    /// sentence ("I'm not sure") never approves.
    static func evaluate(forTranscript text: String, approveWords: [String]) -> AuthorizationVoiceDecision {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return .none }

        if tokens.contains(where: { denyWordList.contains($0) }) {
            return .deny
        }

        let negated = tokens.contains(where: { negationWordList.contains($0) })
        guard !negated else { return .none }

        if containsTokenSequence(tokens, matchingAny: approveWords) {
            return .approve
        }
        return .none
    }

    private static let denyWordList = ["cancel", "deny", "stop", "abort", "nevermind"]
    private static let negationWordList = ["not", "no", "dont", "cant", "cannot", "never", "neither", "nor"]

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func containsTokenSequence(_ tokens: [String], matchingAny phrases: [String]) -> Bool {
        phrases.contains { phrase in
            let parts = phrase.split(separator: " ").map(String.init)
            guard !parts.isEmpty, parts.count <= tokens.count else { return false }
            for start in 0...(tokens.count - parts.count) {
                if Array(tokens[start..<(start + parts.count)]) == parts { return true }
            }
            return false
        }
    }
}
