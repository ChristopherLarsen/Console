import Foundation
import SwiftUI
import FoundationModels

@available(macOS 26.0, *)
@Observable
@MainActor
final class CommandViewModel {

    // MARK: - Public State

    private(set) var commands: [CommandEntry] = []
    private(set) var isProcessing = false
    private(set) var slmAvailable = false
    private(set) var errorMessage: String?

    // MARK: - SLM Session

    private var session: LanguageModelSession?

    private let fillerUtterances: Set<String> = [
        "ah", "uh", "um", "mm", "mmm", "hmm", "hm",
        "huh", "eh", "oh", "er", "erm", "mhm", "uhh",
        "ahh", "umm", "uhm"
    ]

    init() {
        let available = SystemLanguageModel.default.isAvailable
        self.slmAvailable = available
        if available {
            setupSession()
        } else {
            self.errorMessage = "Apple Intelligence is not available. Check System Settings > Apple Intelligence & Siri."
        }
    }

    // MARK: - Session Setup

    private func setupSession() {
        session = LanguageModelSession(
            tools: [OpenApplicationTool(), SystemControlTool()],
            instructions: """
            You are a macOS command executor for the Console app. \
            Parse the user's natural language request and call the appropriate tool. \
            Available tools: openApplication (open a Mac app by name), \
            systemControl (setVolume 0-100, toggleDarkMode). \
            Always call a tool when you can match the request. \
            If the request doesn't match any tool, reply with exactly: No command phrase detected
            """
        )
        session?.prewarm()
    }

    // MARK: - Public API

    func processCommand(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isFillerUtterance(trimmed) { return }

        guard slmAvailable, let session else {
            errorMessage = "Apple Intelligence is not available on this device."
            return
        }

        let entry = CommandEntry(inputText: trimmed)
        commands.append(entry)
        entry.status = .executing
        isProcessing = true
        errorMessage = nil

        do {
            let response = try await session.respond(to: trimmed)
            entry.status = .completed
            let content = response.content
            let lower = content.lowercased()
            if lower.contains("sorry") || lower.contains("cannot assist") || lower.contains("can't assist") {
                entry.resultMessage = "No command phrase detected"
            } else {
                entry.resultMessage = content
            }
        } catch {
            entry.status = .failed
            entry.resultMessage = error.localizedDescription
        }

        isProcessing = false
    }

    func clearCommands() {
        commands.removeAll()
    }

    // MARK: - Filler Detection

    func isFillerUtterance(_ text: String) -> Bool {
        let cleaned = text.lowercased().filter { $0.isLetter }
        return fillerUtterances.contains(cleaned)
    }
}
