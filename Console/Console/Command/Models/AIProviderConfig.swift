import Foundation

struct AIProviderConfig: Codable {
    var provider: AIProvider
    var endpointURL: String
    var apiKeyKeychainRef: String
    var modelName: String

    static let defaultConfigs: [AIProvider: AIProviderConfig] = [
        .openAI: AIProviderConfig(
            provider: .openAI,
            endpointURL: "https://api.openai.com/v1/chat/completions",
            apiKeyKeychainRef: "ai-provider-openAI",
            modelName: "gpt-4o"
        ),
        .claude: AIProviderConfig(
            provider: .claude,
            endpointURL: "https://api.anthropic.com/v1/messages",
            apiKeyKeychainRef: "ai-provider-claude",
            modelName: "claude-sonnet-4-5-20250929"
        ),
        .gemini: AIProviderConfig(
            provider: .gemini,
            endpointURL: "https://generativelanguage.googleapis.com/v1beta/models",
            apiKeyKeychainRef: "ai-provider-gemini",
            modelName: "gemini-2.0-flash"
        ),
        .grok: AIProviderConfig(
            provider: .grok,
            endpointURL: "https://api.x.ai/v1/chat/completions",
            apiKeyKeychainRef: "ai-provider-grok",
            modelName: "grok-2-latest"
        ),
        .lmStudio: AIProviderConfig(
            provider: .lmStudio,
            endpointURL: LMStudioAPI.defaultOrigin,
            apiKeyKeychainRef: "ai-provider-lmStudio",
            modelName: ""
        ),
    ]
}
