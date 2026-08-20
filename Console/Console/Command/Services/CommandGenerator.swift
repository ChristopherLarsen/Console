import Foundation

// MARK: - Command Generator

final class CommandGenerator {
    private let aiProviderManager: AIProviderManager
    private let catalogManager = ActionCatalogManager.shared
    private let validator = CommandValidator()

    init(aiProviderManager: AIProviderManager) {
        self.aiProviderManager = aiProviderManager
    }

    /// Generate a Command from natural language, with catalog context and retry.
    func generateCommand(
        from description: String,
        triggerPhrases: String = "",
        maxRetries: Int = 3
    ) async throws -> Command {
        let provider = aiProviderManager.selectedProvider
        guard provider != .none else {
            throw LLMGeneratorError.missingAPIKey
        }
        let storedKey = await aiProviderManager.loadAPIKey(for: provider)
        if provider.requiresAPIKey {
            guard let apiKey = storedKey, !apiKey.isEmpty else {
                throw LLMGeneratorError.missingAPIKey
            }
        }
        let apiKey = aiProviderManager.effectiveAPIKey(stored: storedKey, for: provider)

        let config = aiProviderManager.config(for: provider)
        guard let client = LLMClientFactory.makeClient(provider: provider, apiKey: apiKey, config: config) else {
            throw LLMGeneratorError.apiError("Failed to create LLM client for \(provider.displayName)")
        }

        let systemPrompt = buildSystemPrompt()
        let userMessage = buildUserMessage(description: description, triggerPhrases: triggerPhrases)

        let responseText = try await RetryHelper.withRetry(maxAttempts: maxRetries) {
            try await client.sendMessage(systemPrompt: systemPrompt, userMessage: userMessage)
        }

        let command = try CommandResponseParser.parse(responseText)

        let enriched = enrichWithUserPhrases(command: command, description: description, triggerPhrases: triggerPhrases)

        try validateGenerated(enriched)

        return enriched
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt() -> String {
        let catalog = catalogManager.getCatalog()
        let context = UserContext.current()
        return SystemPrompt.generate(catalog: catalog, userContext: context)
    }

    private func buildUserMessage(description: String, triggerPhrases: String) -> String {
        var message = description

        if !triggerPhrases.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\nUser-specified trigger phrases: \(triggerPhrases)"
        }

        if let catalog = catalogManager.getCatalog() {
            let relevantApps = findRelevantApps(for: description, in: catalog)
            if !relevantApps.isEmpty {
                let names = relevantApps.map { "\($0.name) (\($0.bundleID))" }.joined(separator: ", ")
                message += "\n\nRelevant installed apps: \(names)"
            }
        }

        return message
    }

    // MARK: - Catalog Integration

    private func findRelevantApps(for description: String, in catalog: ActionCatalog) -> [AppCatalogEntry] {
        let lower = description.lowercased()
        return catalog.apps.filter { entry in
            lower.contains(entry.name.lowercased()) ||
            entry.commonPatterns.contains { lower.contains($0.userIntent.lowercased()) }
        }
    }

    // MARK: - Post-Processing

    private func enrichWithUserPhrases(command: Command, description: String, triggerPhrases: String) -> Command {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var merged: [String] = trimmedDescription.isEmpty ? [] : [trimmedDescription]

        let userPhrases = triggerPhrases
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for phrase in userPhrases {
            if !merged.contains(where: { $0.lowercased() == phrase.lowercased() }) {
                merged.append(phrase)
            }
        }

        // Backward compatibility: merge any LLM-provided phrases
        for phrase in command.triggerPhrases {
            if !merged.contains(where: { $0.lowercased() == phrase.lowercased() }) {
                merged.append(phrase)
            }
        }

        command.triggerPhrases = merged
        return command
    }

    // MARK: - Validation

    private func validateGenerated(_ command: Command) throws {
        guard !command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMGeneratorError.decodingFailed("Generated command has no name")
        }
        guard !command.actions.isEmpty else {
            throw LLMGeneratorError.decodingFailed("Generated command has no actions")
        }

        let validation = validator.validateCommand(command)
        switch validation {
        case .success, .requiresConfirmation:
            break
        case .failure(let error):
            throw LLMGeneratorError.decodingFailed("Validation failed: \(error)")
        }
    }
}
