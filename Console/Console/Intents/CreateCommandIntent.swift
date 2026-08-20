import AppIntents
import SwiftData

struct CreateCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Command"
    static var description = IntentDescription(
        "Generate a new Console command from a natural language description using your configured AI provider."
    )

    @Parameter(title: "Description")
    var commandDescription: String

    @Parameter(title: "Trigger Phrases", default: "")
    var triggerPhrases: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = AppDependencies.shared.modelContainer,
              let aiProviderManager = AppDependencies.shared.aiProviderManager else {
            throw IntentError.notReady
        }

        guard let generator = await aiProviderManager.generator() else {
            throw IntentError.noProviderConfigured
        }

        var prompt = commandDescription
        let phrases = triggerPhrases.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phrases.isEmpty {
            prompt += "\n\nUser-specified trigger phrases: \(phrases)"
        }

        let command: Command
        do {
            command = try await RetryHelper.withRetry(maxAttempts: 3) {
                try await generator.generateCommand(from: prompt)
            }
        } catch {
            throw IntentError.generationFailed(error.localizedDescription)
        }

        let validator = CommandValidator()
        let validation = validator.validateCommand(command)
        if case .failure(let msg) = validation {
            throw IntentError.generationFailed(msg)
        }

        // Merge user-supplied trigger phrases
        if !phrases.isEmpty {
            let userPhrases = phrases
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for phrase in userPhrases {
                if !command.triggerPhrases.contains(where: { $0.lowercased() == phrase.lowercased() }) {
                    command.triggerPhrases.append(phrase)
                }
            }
        }

        let context = ModelContext(container)
        context.insert(command)
        do {
            try context.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        } catch {
            throw IntentError.generationFailed("Failed to save command: \(error.localizedDescription)")
        }

        return .result(value: "Created command \"\(command.name)\" with \(command.actions.count) action(s).")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Create command from \(\.$commandDescription)")
    }
}
