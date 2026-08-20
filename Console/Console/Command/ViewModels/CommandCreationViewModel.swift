import Foundation
import SwiftData

@Observable
@MainActor
final class CommandCreationViewModel {
    var descriptionText: String = ""
    var triggerPhrasesText: String = ""
    var isVoiceInputActive = false

    private(set) var isGenerating = false
    private(set) var generatedCommand: Command?
    private(set) var editableActions: [CommandAction] = []
    private(set) var editableName: String = ""
    private(set) var editableTriggerPhrases: [String] = []
    private(set) var editableExecutionMode: CommandExecutionMode = .appIntents
    private(set) var errorMessage: String?
    private(set) var hasGenerated = false
    private(set) var validationWarning: String?

    private let aiProviderManager: AIProviderManager
    private let modelContext: ModelContext
    private let validator = CommandValidator()

    init(aiProviderManager: AIProviderManager, modelContext: ModelContext) {
        self.aiProviderManager = aiProviderManager
        self.modelContext = modelContext
    }

    // MARK: - Voice Input

    func applyVoiceTranscript(_ text: String) {
        if descriptionText.isEmpty {
            descriptionText = text
        } else {
            descriptionText += " " + text
        }
    }

    func applyVoiceTranscriptToPhrase(_ text: String) {
        if triggerPhrasesText.isEmpty {
            triggerPhrasesText = text
        } else {
            triggerPhrasesText += " " + text
        }
    }

    // MARK: - Generate

    func generate() async {
        guard !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a command description first."
            return
        }

        isGenerating = true
        errorMessage = nil

        let fullPrompt = buildPrompt()
        let provider = aiProviderManager.selectedProvider
        let providerConfig = aiProviderManager.config(for: provider)
        let catalogAssisted = UserDefaults.standard.bool(forKey: "catalogAssistedGeneration")

        do {
            guard let generator = await aiProviderManager.generator() else {
                errorMessage = "No AI provider configured. Set one up in AI Provider."
                isGenerating = false
                return
            }

            let command = try await RetryHelper.withRetry(maxAttempts: 3) {
                try await generator.generateCommand(from: fullPrompt)
            }

            generatedCommand = command

            // Default command name to the user's trigger phrase (sentence-cased)
            let firstUserPhrase = triggerPhrasesText
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !firstUserPhrase.isEmpty {
                editableName = firstUserPhrase.prefix(1).uppercased() + firstUserPhrase.dropFirst()
            } else {
                editableName = command.name
            }

            editableTriggerPhrases = command.triggerPhrases
            editableActions = command.actions
            editableExecutionMode = command.executionMode

            if !triggerPhrasesText.isEmpty {
                let userPhrases = triggerPhrasesText
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                for phrase in userPhrases {
                    if !editableTriggerPhrases.contains(where: { $0.lowercased() == phrase.lowercased() }) {
                        editableTriggerPhrases.append(phrase)
                    }
                }
            }

            let validationResult = validator.validateCommand(command)
            switch validationResult {
            case .success:
                validationWarning = nil
            case .failure(let msg):
                validationWarning = msg
            case .requiresConfirmation(let msg, _):
                validationWarning = msg
            }

            hasGenerated = true
        } catch {
            let rawResponse = Self.lastRawResponse(for: provider)
            GenerationFailureLogger.log(
                userDescription: descriptionText,
                triggerPhrases: triggerPhrasesText,
                systemPrompt: CommandGeneratorPrompt.system,
                fullPrompt: fullPrompt,
                provider: provider,
                modelName: providerConfig.modelName,
                error: error,
                rawResponse: rawResponse,
                catalogAssisted: catalogAssisted,
                retryAttempts: 3
            )
            printDebug("[CommandCreation] Generation failed: \(error)")
            errorMessage = LLMErrorFormatter.userFriendlyMessage(for: error)
        }

        isGenerating = false
    }

    // MARK: - Regenerate

    func regenerate() async {
        hasGenerated = false
        generatedCommand = nil
        await generate()
    }

    // MARK: - Edit Actions

    func updateActionPayload(at index: Int, payload: String) {
        guard editableActions.indices.contains(index) else { return }
        editableActions[index] = CommandAction(
            id: editableActions[index].id,
            type: editableActions[index].type,
            payload: payload,
            order: editableActions[index].order
        )
    }

    func removeAction(at index: Int) {
        guard editableActions.indices.contains(index) else { return }
        editableActions.remove(at: index)
        reorderActions()
    }

    func updateName(_ name: String) {
        editableName = name
    }

    // MARK: - Conflict Detection

    var conflictingPhrase: String? {
        guard !editableTriggerPhrases.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Command>()
        guard let existing = try? modelContext.fetch(descriptor) else { return nil }
        let existingPhrases = Set(
            existing.flatMap { $0.triggerPhrases.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) } }
        )
        return editableTriggerPhrases.first { existingPhrases.contains($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var hasConflict: Bool { conflictingPhrase != nil }

    // MARK: - Save

    func save() -> Bool {
        let name = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Command name cannot be empty."
            return false
        }
        guard !editableActions.isEmpty else {
            errorMessage = "Command must have at least one action."
            return false
        }

        if let conflict = conflictingPhrase {
            errorMessage = "'\(conflict)' is already used by another command."
            return false
        }

        // Check for reserved phrases
        for phrase in editableTriggerPhrases {
            if isReservedPhrase(phrase) {
                errorMessage = "'\(phrase)' is reserved for a system command and cannot be used."
                return false
            }
        }

        let command = Command(
            name: name,
            triggerPhrases: editableTriggerPhrases,
            actions: editableActions,
            executionMode: editableExecutionMode
        )

        let validationResult = validator.validateCommand(command)
        if case .failure(let msg) = validationResult {
            errorMessage = msg
            return false
        }

        modelContext.insert(command)
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        } catch {
            errorMessage = "Failed to save command."
            return false
        }
        return true
    }

    // MARK: - Private

    private func isReservedPhrase(_ phrase: String) -> Bool {
        let normalized = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let reservedPhrases = ConsoleCommandRegistry.all
            .flatMap { $0.triggerPhrases }
            .map { $0.lowercased() }

        return reservedPhrases.contains(normalized)
    }

    private static func lastRawResponse(for provider: AIProvider) -> String? {
        switch provider {
        case .openAI: return OpenAICommandGenerator.lastRawResponse
        case .claude: return ClaudeCommandGenerator.lastRawResponse
        case .gemini: return GeminiCommandGenerator.lastRawResponse
        case .grok: return GrokCommandGenerator.lastRawResponse
        case .lmStudio: return LMStudioCommandGenerator.lastRawResponse
        case .none: return nil
        }
    }

    private func buildPrompt() -> String {
        var prompt = descriptionText
        if !triggerPhrasesText.isEmpty {
            prompt += "\n\nUser-specified trigger phrases: \(triggerPhrasesText)"
        }
        let useCatalog = UserDefaults.standard.bool(forKey: "catalogAssistedGeneration")
        if useCatalog {
            // TODO: Inject relevant CatalogEntry context here when catalog integration is implemented
        }
        return prompt
    }

    private func reorderActions() {
        for i in editableActions.indices {
            editableActions[i] = CommandAction(
                id: editableActions[i].id,
                type: editableActions[i].type,
                payload: editableActions[i].payload,
                order: i
            )
        }
    }
}
