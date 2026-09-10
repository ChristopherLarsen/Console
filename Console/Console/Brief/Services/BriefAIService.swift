import Foundation

/// Errors surfaced by the AI refinement pass.
enum BriefAIError: LocalizedError {
    case noProvider
    case noAPIKey
    case clientCreationFailed
    case refinementFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return "No AI provider configured. Set one in AI Provider."
        case .noAPIKey:
            return "No API key found for the selected provider."
        case .clientCreationFailed:
            return "Failed to create AI client."
        case .refinementFailed(let message):
            return message
        case .invalidResponse:
            return "The AI response could not be parsed into report lines."
        }
    }
}

/// Testable seam for Brief AI polish. Production uses `BriefAIService`;
/// tests inject a suspended refiner so in-flight operations can be tested.
@MainActor
protocol BriefRefining {
    func refine(yesterdayLines: [String]) async throws -> BriefAIResponseParser.Parsed
}

@MainActor
struct ProviderBackedBriefRefiner: BriefRefining {
    let aiProviderManager: AIProviderManager

    func refine(yesterdayLines: [String]) async throws -> BriefAIResponseParser.Parsed {
        try await BriefAIService.refine(
            yesterdayLines: yesterdayLines,
            aiProviderManager: aiProviderManager
        )
    }
}

/// Explicit, user-triggered AI polish of a brief. Sends only content already
/// derived locally (commit subjects); never JIRA/GitLab web content. Runs
/// only when the user asks for it — never automatically.
enum BriefAIService {
    static let systemPrompt = """
        You compress a developer's previous-workday commit activity into a \
        terse executive status report for a morning stand-up meeting.
        Return EXACTLY this format and nothing else:
        Y1 | <most important thing done yesterday>
        Y2 | <second>
        Y3 | <third>
        Rules: plain text only; no markdown, bullets, or quotes; at most 70 \
        characters per line; keep concrete repo and ticket names; never \
        invent facts not present in the input.
        """

    static func refine(yesterdayLines: [String],
                       aiProviderManager: AIProviderManager) async throws -> BriefAIResponseParser.Parsed {
        let provider = aiProviderManager.selectedProvider
        guard provider != .none else { throw BriefAIError.noProvider }

        let storedKey = await aiProviderManager.loadAPIKey(for: provider)
        if provider.requiresAPIKey {
            guard let apiKey = storedKey, !apiKey.isEmpty else {
                throw BriefAIError.noAPIKey
            }
        }
        let apiKey = aiProviderManager.effectiveAPIKey(stored: storedKey, for: provider)

        let config = aiProviderManager.config(for: provider)
        guard let client = LLMClientFactory.makeClient(
            provider: provider,
            apiKey: apiKey,
            config: config
        ) else {
            throw BriefAIError.clientCreationFailed
        }

        let userMessage = """
            Yesterday's commits:
            \(yesterdayLines.joined(separator: "\n"))
            """

        do {
            let response = try await client.sendMessage(systemPrompt: systemPrompt,
                                                        userMessage: userMessage)
            guard let parsed = BriefAIResponseParser.parse(response) else {
                throw BriefAIError.invalidResponse
            }
            return parsed
        } catch let error as BriefAIError {
            throw error
        } catch {
            throw BriefAIError.refinementFailed(error.localizedDescription)
        }
    }
}
