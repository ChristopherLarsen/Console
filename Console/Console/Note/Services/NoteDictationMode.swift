import Foundation
import AVFoundation

enum NoteVoiceCommand: String, CaseIterable {
    // case copy, undo, done, edit, clear
    case copy, undo, done, clear

    static func match(_ text: String, isEditMode: Bool = true) -> NoteVoiceCommand? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter }
        guard let command = Self.allCases.first(where: { $0.rawValue == cleaned }) else {
            return nil
        }
        // "edit" disabled for now — will return in a future release
        // if command == .edit { return command }
        return command
    }
}

@available(macOS 26.0, *)
@Observable
@MainActor
final class NoteDictationMode: ListeningMode {

    // MARK: - ListeningMode Conformance

    let modeIdentifier = "noteDictation"
    let priority: ModePriority = .exclusive
    private(set) var isActive = false

    // MARK: - Dependencies

    private let noteViewModel: NoteViewModel
    private let aiProviderManager: AIProviderManager

    // MARK: - Transcription State

    private var transcriber: SpokenWordTranscriber?
    private var audioStreamTask: Task<Void, Never>?
    private(set) var volatileText: String = ""
    var fullTranscript: String {
        guard let transcriber else { return noteViewModel.noteText }
        let text = String(transcriber.finalizedTranscript.characters)
        return text.isEmpty ? noteViewModel.noteText : text
    }
    private var isTranscriptionPaused = false
    private var speechBuffer: String = ""
    private var lastFinalizedLength: Int = 0

    // MARK: - Voice Command Detection

    private var commandDeferralTimer: Timer?
    private var pendingCommand: (command: ConsoleCommand, precedingText: String)?
    private var volatileCommandTimer: Timer?
    private var volatileCommandCandidate: ConsoleCommand?
    private var lastVolatileCommandTime: Date?

    // MARK: - Pause Detection

    private var silenceTimer: Timer?

    // MARK: - Formatting Watch

    private var formattingWatchTask: Task<Void, Never>?

    init(noteViewModel: NoteViewModel, aiProviderManager: AIProviderManager) {
        self.noteViewModel = noteViewModel
        self.aiProviderManager = aiProviderManager
    }

    // MARK: - ListeningMode Protocol

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        lastFinalizedLength = 0
        speechBuffer = ""
        isTranscriptionPaused = false

        noteViewModel.onClearRequested = { [weak self] in
            self?.resetTranscription()
        }

        #if DEBUG
        if AudioSessionController._unitTestMode {
            // Unit tests must not require live Speech hardware: activate
            // state only; transcript state is driven through the view model.
            return
        }
        #endif

        let story = SpeechStory()
        let newTranscriber = SpokenWordTranscriber(story: story)
        self.transcriber = newTranscriber

        newTranscriber.onFinalizedTextUpdate = { [weak self] in
            self?.handleNewFinalizedText()
        }
        newTranscriber.onVolatileTextUpdate = { [weak self] in
            guard let self else { return }
            let text = String(newTranscriber.volatileTranscript.characters)
            self.volatileText = text
            self.noteViewModel.appendVolatileText(text)
            self.checkVolatileForCommand(text)
        }

        do {
            try await newTranscriber.setUpTranscriber()
        } catch {
            printDebug("[NoteDictation] Failed to set up transcriber: \(error)")
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

        startFormattingWatch()
        printDebug("[NoteDictation] Activated")
    }

    func deactivate() async {
        audioStreamTask?.cancel()
        audioStreamTask = nil
        formattingWatchTask?.cancel()
        formattingWatchTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        commandDeferralTimer?.invalidate()
        commandDeferralTimer = nil
        pendingCommand = nil
        volatileCommandTimer?.invalidate()
        volatileCommandTimer = nil
        volatileCommandCandidate = nil

        if !volatileText.isEmpty {
            noteViewModel.finalizeText(volatileText)
            noteViewModel.appendVolatileText("")
            volatileText = ""
        }

        if !speechBuffer.isEmpty {
            noteViewModel.finalizeText(speechBuffer)
            speechBuffer = ""
        }

        // The volatile span was just committed manually above; the final flush
        // below finalizes that same span, so stop the delivery callbacks from
        // appending it a second time.
        transcriber?.onFinalizedTextUpdate = nil
        transcriber?.onVolatileTextUpdate = nil

        do {
            try await transcriber?.finishTranscribing()
        } catch {
            printDebug("[NoteDictation] Error finishing transcriber: \(error)")
        }

        transcriber = nil
        isActive = false
        isTranscriptionPaused = false
        printDebug("[NoteDictation] Deactivated")
    }

    // MARK: - Transcript Processing

    private func handleNewFinalizedText() {
        guard let transcriber else { return }

        // Clear volatile text now that it has been finalized
        volatileText = ""
        noteViewModel.appendVolatileText("")

        let fullText = String(transcriber.finalizedTranscript.characters)
        guard fullText.count > lastFinalizedLength else { return }

        let delta = String(fullText.dropFirst(lastFinalizedLength))
        lastFinalizedLength = fullText.count

        resetSilenceTimer()

        // If volatile detection already fired this command, skip it
        if let lastTime = lastVolatileCommandTime,
           Date().timeIntervalSince(lastTime) < 3.0 {
            let tfMatcher = ConsoleCommandMatcher(confidenceThreshold: 0.80)
            if tfMatcher.bestMatch(for: delta, availableIn: .exclusive) != nil {
                lastVolatileCommandTime = nil
                return
            }
        }

        if let pending = pendingCommand {
            commandDeferralTimer?.invalidate()
            commandDeferralTimer = nil
            pendingCommand = nil
            appendText(pending.precedingText)
        }

        let tfMatcher = ConsoleCommandMatcher(confidenceThreshold: 0.80)
        if let match = Self.exactExclusiveCommand(in: delta) {
            pendingCommand = (command: match.command, precedingText: delta)
            commandDeferralTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let pending = self.pendingCommand else { return }
                    self.pendingCommand = nil
                    _ = await pending.command.handler()
                }
            }
            return
        }

        appendText(delta)
    }

    /// A finalized delta defers a note command only when it is exactly the
    /// command phrase; a fuzzy match like "say copy" is dictated prose whose
    /// words must be kept.
    @available(macOS 26.0, *)
    static func exactExclusiveCommand(in delta: String) -> ConsoleCommandMatch? {
        let matcher = ConsoleCommandMatcher(confidenceThreshold: 0.80)
        guard let match = matcher.bestMatch(for: delta, availableIn: .exclusive) else { return nil }
        let cleanedDelta = delta.lowercased().filter { $0.isLetter }
        let cleanedPhrase = match.triggerPhrase.lowercased().filter { $0.isLetter }
        return cleanedDelta == cleanedPhrase ? match : nil
    }

    // MARK: - Volatile Command Detection

    private func checkVolatileForCommand(_ text: String) {
        let tfMatcher = ConsoleCommandMatcher(confidenceThreshold: 0.80)

        if let match = tfMatcher.bestMatch(for: text, availableIn: .exclusive) {
            guard volatileCommandCandidate != match.command else { return }
            volatileCommandCandidate = match.command
            volatileCommandTimer?.invalidate()
            volatileCommandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let candidate = self.volatileCommandCandidate else { return }
                    self.volatileCommandCandidate = nil
                    self.lastVolatileCommandTime = Date()
                    // Cancel any pending finalized command deferral
                    self.commandDeferralTimer?.invalidate()
                    self.commandDeferralTimer = nil
                    self.pendingCommand = nil
                    printDebug("[NoteDictation] Volatile command detected: \(candidate.id)")
                    _ = await candidate.handler()
                }
            }
        } else {
            volatileCommandTimer?.invalidate()
            volatileCommandTimer = nil
            volatileCommandCandidate = nil
        }
    }

    private func appendText(_ text: String) {
        if isTranscriptionPaused {
            speechBuffer += text
        } else {
            noteViewModel.finalizeText(text)
        }
    }

    private func resetTranscription() {
        speechBuffer = ""
        volatileText = ""
        noteViewModel.appendVolatileText("")
        commandDeferralTimer?.invalidate()
        commandDeferralTimer = nil
        pendingCommand = nil
        volatileCommandTimer?.invalidate()
        volatileCommandTimer = nil
        volatileCommandCandidate = nil
        // Advance past all existing finalized text so late callbacks don't re-append
        if let transcriber {
            lastFinalizedLength = String(transcriber.finalizedTranscript.characters).count
        }
    }

    // MARK: - Pause Detection (Paragraph Breaks)

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePauseDetected()
            }
        }
    }

    private func handlePauseDetected() {
        noteViewModel.deactivateFish()
        noteViewModel.handleParagraphBreak()
    }

    // MARK: - Formatting Watch

    /// Observes noteViewModel.isFormatting to auto-pause/resume text delivery.
    private func startFormattingWatch() {
        formattingWatchTask = Task { [weak self] in
            var wasFormatting = false
            while !Task.isCancelled {
                guard let self else { return }
                let isNowFormatting = self.noteViewModel.isFormatting
                if !wasFormatting && isNowFormatting {
                    self.isTranscriptionPaused = true
                    self.speechBuffer = ""
                } else if wasFormatting && !isNowFormatting {
                    if !self.speechBuffer.isEmpty {
                        self.noteViewModel.finalizeText(self.speechBuffer)
                        self.speechBuffer = ""
                    }
                    self.isTranscriptionPaused = false
                }
                wasFormatting = isNowFormatting
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
