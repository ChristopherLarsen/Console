import Foundation

enum NoteFormattingError: LocalizedError {
    case noProvider
    case noAPIKey
    case clientCreationFailed
    case formattingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return "No AI provider configured. Set one in AI Provider."
        case .noAPIKey:
            return "No API key found for the selected provider."
        case .clientCreationFailed:
            return "Failed to create AI client."
        case .formattingFailed(let message):
            return message
        }
    }
}

enum NoteFormattingService {
    private static let systemPrompt = """
        You are a text formatter. The user will give you raw dictated text. \
        Clean it up into well-structured Markdown. Fix punctuation, capitalization, \
        and paragraph breaks. Do not add, remove, or change the meaning of any content. \
        Do not add commentary or explanations. Return only the formatted Markdown text.
        """

    @MainActor
    static func format(text: String, aiProviderManager: AIProviderManager) async throws -> String {
        let provider = aiProviderManager.selectedProvider
        guard provider != .none else { throw NoteFormattingError.noProvider }

        let storedKey = await aiProviderManager.loadAPIKey(for: provider)
        if provider.requiresAPIKey {
            guard let apiKey = storedKey, !apiKey.isEmpty else {
                throw NoteFormattingError.noAPIKey
            }
        }
        let apiKey = aiProviderManager.effectiveAPIKey(stored: storedKey, for: provider)

        let config = aiProviderManager.config(for: provider)
        guard let client = LLMClientFactory.makeClient(
            provider: provider,
            apiKey: apiKey,
            config: config
        ) else {
            throw NoteFormattingError.clientCreationFailed
        }

        do {
            return try await client.sendMessage(systemPrompt: systemPrompt, userMessage: text)
        } catch {
            throw NoteFormattingError.formattingFailed(error.localizedDescription)
        }
    }
}
