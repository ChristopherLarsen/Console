import Foundation

struct OpenAICommandGenerator: LLMCommandGenerator {
    nonisolated(unsafe) static var lastRawResponse: String?

    let apiKey: String
    let config: AIProviderConfig

    func generateCommand(from naturalLanguage: String) async throws -> Command {
        OpenAICommandGenerator.lastRawResponse = nil

        let client = OpenAIClient(apiKey: apiKey, config: config)
        let text = try await client.sendMessage(
            systemPrompt: CommandGeneratorPrompt.system,
            userMessage: naturalLanguage
        )

        OpenAICommandGenerator.lastRawResponse = text
        return try CommandResponseParser.parse(text)
    }
}
