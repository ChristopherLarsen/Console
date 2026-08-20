import Foundation

struct ClaudeCommandGenerator: LLMCommandGenerator {
    nonisolated(unsafe) static var lastRawResponse: String?

    let apiKey: String
    let config: AIProviderConfig

    func generateCommand(from naturalLanguage: String) async throws -> Command {
        ClaudeCommandGenerator.lastRawResponse = nil

        let client = ClaudeClient(apiKey: apiKey, config: config)
        let text = try await client.sendMessage(
            systemPrompt: CommandGeneratorPrompt.system,
            userMessage: naturalLanguage
        )

        ClaudeCommandGenerator.lastRawResponse = text
        return try CommandResponseParser.parse(text)
    }
}
