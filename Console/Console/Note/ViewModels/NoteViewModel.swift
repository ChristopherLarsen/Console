import AppKit
import SwiftUI

@Observable
@MainActor
final class NoteViewModel {
    static var shared: NoteViewModel?

    var noteText: String = ""
    var isEditMode: Bool = false
    var isListeningPaused: Bool = false
    private(set) var isFormatting: Bool = false
    private(set) var showCopiedFeedback: Bool = false
    private(set) var showPauseIndicator: Bool = false
    var formatError: String?
    private(set) var volatileText: String = ""
    private(set) var fishIsActive: Bool = false
    var isPinned: Bool = false

    private var undoStack: [String] = []
    private var pausePoints: [Int] = []
    @ObservationIgnored private var copiedFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var pauseIndicatorTask: Task<Void, Never>?
    @ObservationIgnored var onClearRequested: (() -> Void)?

    private let aiProviderManager: AIProviderManager?

    // Throttle volatile text updates so the layout pass can complete between changes
    @ObservationIgnored private var lastVolatileUpdateTime: ContinuousClock.Instant = .now
    @ObservationIgnored private var pendingVolatileText: String?
    @ObservationIgnored private var volatileThrottleTask: Task<Void, Never>?
    private let volatileMinInterval: Duration = .milliseconds(80)

    init(aiProviderManager: AIProviderManager?) {
        self.aiProviderManager = aiProviderManager
    }

    // MARK: - Public API for NoteDictationMode

    func appendVolatileText(_ text: String) {
        // Always apply clears immediately
        if text.isEmpty {
            volatileThrottleTask?.cancel()
            volatileThrottleTask = nil
            pendingVolatileText = nil
            volatileText = text
            lastVolatileUpdateTime = .now
            return
        }

        activateFish()
        NotificationCenter.default.post(name: .voiceActivityDetected, object: nil)

        let elapsed = ContinuousClock.now - lastVolatileUpdateTime
        if elapsed >= volatileMinInterval {
            volatileThrottleTask?.cancel()
            volatileThrottleTask = nil
            pendingVolatileText = nil
            volatileText = text
            lastVolatileUpdateTime = .now
        } else {
            pendingVolatileText = text
            if volatileThrottleTask == nil {
                volatileThrottleTask = Task { [weak self] in
                    try? await Task.sleep(for: self?.volatileMinInterval ?? .milliseconds(80))
                    guard let self, let pending = self.pendingVolatileText else { return }
                    self.volatileText = pending
                    self.pendingVolatileText = nil
                    self.lastVolatileUpdateTime = .now
                    self.volatileThrottleTask = nil
                }
            }
        }
    }

    func finalizeText(_ text: String) {
        noteText += text
    }

    func handleVoiceCommand(_ command: NoteVoiceCommand) {
        SoundFeedbackService.shared.play(.noteCommandRecognized)
        switch command {
        case .undo: undo()
        case .copy: copyToClipboard()
        case .done: done()
        // case .edit: toggleEditMode()
        case .clear: clearNote()
        }
    }

    func togglePin() {
        isPinned.toggle()
        NotePanelController.shared.setWindowPinned(isPinned)
    }

    func toggleEditMode() {
        isEditMode.toggle()
    }

    func clearNote() {
        noteText = ""
        appendVolatileText("")
        undoStack.removeAll()
        pausePoints.removeAll()
        onClearRequested?()
    }

    func handleParagraphBreak() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !noteText.hasSuffix("\n\n") else { return }
        noteText += "\n\n"
        pausePoints.append(noteText.count)
        flashPauseIndicator()
    }

    // MARK: - Copy

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(noteText, forType: .string)
        showCopiedFeedback = true
        copiedFeedbackTask?.cancel()
        copiedFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            showCopiedFeedback = false
        }
    }

    // MARK: - Format

    func formatNote() {
        guard !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isFormatting else { return }

        if UserDefaults.standard.bool(forKey: "noteFormattingEnabled") {
            formatNoteWithAI()
        } else {
            formatNoteAlgorithmically()
        }
    }

    private func formatNoteWithAI() {
        guard let aiProviderManager else {
            formatError = "No AI provider configured"
            return
        }
        undoStack.append(noteText)
        isFormatting = true
        formatError = nil
        SoundFeedbackService.shared.play(.noteFormatStarted)

        Task {
            do {
                let result = try await NoteFormattingService.format(
                    text: noteText,
                    aiProviderManager: aiProviderManager
                )
                noteText = result
                pausePoints.removeAll()
                SoundFeedbackService.shared.play(.noteFormatCompleted)
            } catch {
                formatError = error.localizedDescription
                if let restored = undoStack.popLast() {
                    noteText = restored
                }
            }
            isFormatting = false
        }
    }

    private func formatNoteAlgorithmically() {
        // TODO: Implement local formatting logic
    }

    // MARK: - Undo

    func undo() {
        if !undoStack.isEmpty {
            noteText = undoStack.removeLast()
            rebuildPausePoints()
            return
        }

        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Strip trailing whitespace/newlines so undo looks past paragraph breaks
        var workingText = noteText
        while workingText.last?.isWhitespace == true || workingText.last?.isNewline == true {
            workingText.removeLast()
        }

        let sentenceEndings: [String] = [". ", "! ", "? ", ".\n", "!\n", "?\n"]
        var lastSentenceEnd: String.Index?

        for ending in sentenceEndings {
            if let range = workingText.range(of: ending, options: .backwards) {
                if lastSentenceEnd == nil || range.upperBound > lastSentenceEnd! {
                    lastSentenceEnd = range.upperBound
                }
            }
        }

        let lastParagraphBreak = workingText.range(of: "\n\n", options: .backwards)

        if let sentEnd = lastSentenceEnd, let paraBreak = lastParagraphBreak {
            if sentEnd > paraBreak.upperBound {
                noteText = String(workingText[workingText.startIndex..<sentEnd])
            } else {
                noteText = String(workingText[workingText.startIndex..<paraBreak.upperBound])
            }
        } else if let sentEnd = lastSentenceEnd {
            noteText = String(workingText[workingText.startIndex..<sentEnd])
        } else if let paraBreak = lastParagraphBreak {
            noteText = String(workingText[workingText.startIndex..<paraBreak.upperBound])
        } else {
            noteText = ""
        }

        rebuildPausePoints()
    }

    func done() {
        // Show copied feedback immediately
        if !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showCopiedFeedback = true
        }

        Task {
            for _ in 0..<4 {
                if volatileText.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Volatile text still awaiting finalization belongs on the
            // clipboard; it may only reach the note after dismissal.
            let text = noteText + volatileText
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            NotePanelController.shared.dismiss()
        }
    }

    // MARK: - Helpers

    private func flashPauseIndicator() {
        pauseIndicatorTask?.cancel()
        showPauseIndicator = true
        pauseIndicatorTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            showPauseIndicator = false
        }
    }

    private func rebuildPausePoints() {
        pausePoints.removeAll()
        var searchStart = noteText.startIndex
        while let range = noteText.range(of: "\n\n", range: searchStart..<noteText.endIndex) {
            pausePoints.append(noteText.distance(from: noteText.startIndex, to: range.upperBound))
            searchStart = range.upperBound
        }
    }

    // MARK: - Fish Cursor State

    private func activateFish() {
        fishIsActive = true
    }

    func deactivateFish() {
        fishIsActive = false
    }
}
