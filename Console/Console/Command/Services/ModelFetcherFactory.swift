import Foundation

enum ModelFetcherFactory {
    static func makeFetcher(
        provider: AIProvider,
        apiKey: String,
        config: AIProviderConfig
    ) -> (any ModelFetcher)? {
        switch provider {
        case .openAI:
            return OpenAIModelFetcher(apiKey: apiKey, config: config)
        case .claude:
            return ClaudeModelFetcher(apiKey: apiKey, config: config)
        case .gemini:
            return GeminiModelFetcher(apiKey: apiKey, config: config)
        case .grok:
            return GrokModelFetcher(apiKey: apiKey, config: config)
        case .lmStudio:
            return LMStudioModelFetcher(config: config)
        case .none:
            return nil
        }
    }
}
