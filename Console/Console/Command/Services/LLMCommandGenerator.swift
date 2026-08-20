import Foundation

@MainActor
protocol LLMCommandGenerator {
    func generateCommand(from naturalLanguage: String) async throws -> Command
}

enum LLMGeneratorError: Error, LocalizedError {
    case invalidResponse
    case apiError(String)
    case decodingFailed(String)
    case missingAPIKey
    case networkError(Error)

    // AI-reported errors
    case notAvailable(message: String, suggestion: String?)
    case ambiguousRequest(message: String, suggestion: String?)
    case tooComplex(message: String, suggestion: String?)
    case safetyExceeded(message: String, suggestion: String?)
    case unknownError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI provider returned an invalid response."
        case .apiError(let message):
            return "API error: \(message)"
        case .decodingFailed(let detail):
            return "Failed to parse AI response: \(detail)"
        case .missingAPIKey:
            return "No API key configured for the selected provider."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .notAvailable(let message, let suggestion):
            return formatErrorMessage(message: message, suggestion: suggestion)
        case .ambiguousRequest(let message, let suggestion):
            return formatErrorMessage(message: message, suggestion: suggestion)
        case .tooComplex(let message, let suggestion):
            return formatErrorMessage(message: message, suggestion: suggestion)
        case .safetyExceeded(let message, let suggestion):
            return formatErrorMessage(message: message, suggestion: suggestion)
        case .unknownError(let message):
            return message
        }
    }

    private func formatErrorMessage(message: String, suggestion: String?) -> String {
        if let suggestion = suggestion, !suggestion.isEmpty {
            return "\(message)\n\n\(suggestion)"
        }
        return message
    }
}
