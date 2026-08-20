import Foundation

struct GrokCommandGenerator: LLMCommandGenerator {
    nonisolated(unsafe) static var lastRawResponse: String?

    let apiKey: String
    let config: AIProviderConfig

    func generateCommand(from naturalLanguage: String) async throws -> Command {
        GrokCommandGenerator.lastRawResponse = nil

        let client = GrokClient(apiKey: apiKey, config: config)
        let text = try await client.sendMessage(
            systemPrompt: CommandGeneratorPrompt.system,
            userMessage: naturalLanguage
        )

        GrokCommandGenerator.lastRawResponse = text
        return try CommandResponseParser.parse(text)
    }
}
