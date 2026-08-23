import Foundation

/// Errors surfaced by the Next decision pass.
enum NextTaskError: LocalizedError {
    case noProvider
    case noAPIKey
    case clientCreationFailed
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return "No AI provider configured. Set one in AI Provider."
        case .noAPIKey:
            return "No API key found for the selected provider."
        case .clientCreationFailed:
            return "Failed to create AI client."
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "The AI response could not be parsed into a next task."
        }
    }
}

/// Explicit, user-triggered "what should I do next" call. Sends only the
/// locally gathered snapshot (MR list rows, session names/states, ticket
/// rows); never page bodies or terminal content.
enum NextTaskService {
    static let systemPrompt = """
        You pick the single most valuable thing for a developer to do next. \
        You are given four lists: MRs TO REVIEW, MY OPEN MRs, SESSIONS NEEDING \
        ATTENTION, TICKETS. Respect this priority order: 1) reviewing someone \
        else's MR, 2) addressing reviewer comments on their own MR (review \
        states like "Changes requested", failed pipeline, blocked), 3) an \
        agent session that needs attention, 4) starting a new ticket. Within \
        a priority, prefer items that need attention most urgently.
        Return EXACTLY one JSON object and nothing else, with this schema:
        {"task":"review_mr|address_comments|session_attention|new_ticket",\
        "headline":"<=60 chars","lines":["line1","line2"],"target_url":null,\
        "session_name":null}
        Rules: headline is an imperative ("Review !88 in AntivirusGodot"). \
        lines holds 1-3 short supporting facts copied from the input; never \
        invent facts. For task review_mr or address_comments set target_url \
        to that item's URL from the input and leave session_name null. For \
        session_attention copy the exact session name into session_name and \
        set target_url null. For new_ticket set both null.
        """

    static func determineNextTask(
        snapshot: NextContextSnapshot,
        aiProviderManager: AIProviderManager
    ) async throws -> NextTask {
        let provider = aiProviderManager.selectedProvider
        guard provider != .none else { throw NextTaskError.noProvider }

        let storedKey = await aiProviderManager.loadAPIKey(for: provider)
        if provider.requiresAPIKey {
            guard let apiKey = storedKey, !apiKey.isEmpty else {
                throw NextTaskError.noAPIKey
            }
        }
        let apiKey = aiProviderManager.effectiveAPIKey(stored: storedKey, for: provider)

        let config = aiProviderManager.config(for: provider)
        guard let client = LLMClientFactory.makeClient(
            provider: provider,
            apiKey: apiKey,
            config: config
        ) else {
            throw NextTaskError.clientCreationFailed
        }

        do {
            let response = try await client.sendMessage(
                systemPrompt: systemPrompt,
                userMessage: promptText(snapshot)
            )
            guard let task = NextTaskResponseParser.parse(response) else {
                throw NextTaskError.invalidResponse
            }
            return task
        } catch let error as NextTaskError {
            throw error
        } catch {
            throw NextTaskError.requestFailed(error.localizedDescription)
        }
    }

    private static func promptText(_ snapshot: NextContextSnapshot) -> String {
        NextContextBuilder.promptText(for: snapshot)
    }
}
