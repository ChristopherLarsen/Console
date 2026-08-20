import Foundation

struct LMStudioCommandGenerator: LLMCommandGenerator {
    nonisolated(unsafe) static var lastRawResponse: String?

    let apiKey: String
    let config: AIProviderConfig

    func generateCommand(from naturalLanguage: String) async throws -> Command {
        LMStudioCommandGenerator.lastRawResponse = nil

        let client = LMStudioClient(apiKey: apiKey, config: config)
        let text = try await client.sendMessage(
            systemPrompt: CommandGeneratorPrompt.system,
            userMessage: naturalLanguage
        )

        LMStudioCommandGenerator.lastRawResponse = text
        return try CommandResponseParser.parse(text)
    }
}
