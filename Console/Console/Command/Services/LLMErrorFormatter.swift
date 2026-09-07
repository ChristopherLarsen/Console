import Foundation

enum LLMErrorFormatter {
    static func userFriendlyMessage(for error: Error) -> String {
        if let llmError = error as? LLMGeneratorError {
            return formatLLMError(llmError)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return formatNetworkError(nsError)
        }

        return "An unexpected error occurred: \(error.localizedDescription)"
    }

    private static func formatLLMError(_ error: LLMGeneratorError) -> String {
        switch error {
        case .invalidResponse:
            return "The AI returned an unexpected response format. Try regenerating."

        case .apiError(let message):
            // A leading bracketed status is the authoritative HTTP result;
            // classify by it before falling back to phrase heuristics so a
            // body mentioning "500"/"429" cannot mislabel a 4xx response.
            if let status = LLMAPIStatus.fromAPIMessage(message) {
                return formatHTTPStatus(status, originalMessage: message)
            }

            let lower = message.lowercased()

            if lower.contains("401") || lower.contains("unauthorized") || lower.contains("invalid api key") {
                return "Invalid API key. Check your API key in AI Provider."
            }
            if lower.contains("403") || lower.contains("forbidden") {
                return "Access denied. Your API key may lack the required permissions."
            }
            if lower.contains("429") || lower.contains("rate limit") {
                return "Rate limit exceeded. Wait a moment and try again."
            }
            if lower.contains("402") || lower.contains("insufficient") || lower.contains("quota") {
                return "API quota or billing limit reached. Check your provider account."
            }
            if lower.contains("500") || lower.contains("internal server error") {
                return "The AI service had an internal error. Try again shortly."
            }
            if lower.contains("502") || lower.contains("503") || lower.contains("service unavailable") {
                return "The AI service is temporarily unavailable. Try again in a minute."
            }
            if lower.contains("timeout") {
                return "The request timed out. Check your connection and try again."
            }
            if lower.contains("model") && lower.contains("not found") {
                return "The configured model was not found. Check your model name in Settings."
            }

            return "API error: \(message)"

        case .decodingFailed:
            return "The AI could not generate a valid command.\nTry generating with a simpler command description."

        case .missingAPIKey:
            return "No API key configured. Add one in AI Provider."

        case .networkError(let underlying):
            let nsError = underlying as NSError
            return formatNetworkError(nsError)

        // AI-reported errors with enhanced, contextual messages
        case .notAvailable(let message, let suggestion):
            return formatNotAvailableError(message: message, suggestion: suggestion)

        case .ambiguousRequest(let message, let suggestion):
            return formatAmbiguousRequestError(message: message, suggestion: suggestion)

        case .tooComplex(let message, let suggestion):
            return formatTooComplexError(message: message, suggestion: suggestion)

        case .safetyExceeded(let message, let suggestion):
            return formatSafetyExceededError(message: message, suggestion: suggestion)

        case .unknownError(let message):
            return "⚠️ An unexpected error occurred\n\n\(message)\n\nTry rephrasing your command or simplifying the request."
        }
    }

    private static func formatHTTPStatus(_ status: Int, originalMessage message: String) -> String {
        switch status {
        case 401:
            return "Invalid API key. Check your API key in AI Provider."
        case 403:
            return "Access denied. Your API key may lack the required permissions."
        case 429:
            return "Rate limit exceeded. Wait a moment and try again."
        case 402:
            return "API quota or billing limit reached. Check your provider account."
        case 500:
            return "The AI service had an internal error. Try again shortly."
        case 502, 503:
            return "The AI service is temporarily unavailable. Try again in a minute."
        case 504, 529:
            return "The AI service is overloaded or timed out. Try again in a minute."
        default:
            return "API error: \(message)"
        }
    }

    private static func formatNetworkError(_ error: NSError) -> String {
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection. Check your network and try again."
        case NSURLErrorTimedOut:
            return "The request timed out. Check your connection and try again."
        case NSURLErrorNetworkConnectionLost:
            return "Network connection was lost. Try again."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Could not reach the AI service. Check the endpoint URL in Settings."
        case NSURLErrorCannotConnectToHost:
            return "Could not connect to the AI server. If you are using LM Studio, start the local server and try again."
        case NSURLErrorSecureConnectionFailed:
            return "Secure connection failed. The AI endpoint may have a certificate issue."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - AI Error Type Formatters

    private static func formatNotAvailableError(message: String, suggestion: String?) -> String {
        var result = "🚫 Not Available on macOS\n\n\(message)"

        if let suggestion = suggestion, !suggestion.isEmpty {
            result += "\n\n💡 Suggestion: \(suggestion)"
        } else {
            result += "\n\nThis feature or app isn't available on your Mac. Try a different approach or check if you need to install additional software."
        }

        return result
    }

    private static func formatAmbiguousRequestError(message: String, suggestion: String?) -> String {
        var result = "🤔 Need More Details\n\n\(message)"

        if let suggestion = suggestion, !suggestion.isEmpty {
            result += "\n\n💡 Try: \(suggestion)"
        } else {
            result += "\n\nPlease provide more specific information about what you want to do, such as app names, file paths, or exact values."
        }

        return result
    }

    private static func formatTooComplexError(message: String, suggestion: String?) -> String {
        var result = "🧩 Too Complex to Automate\n\n\(message)"

        if let suggestion = suggestion, !suggestion.isEmpty {
            result += "\n\n💡 Alternative: \(suggestion)"
        } else {
            result += "\n\nThis task requires human judgment or decision-making that can't be automated. Consider breaking it into smaller, more specific steps."
        }

        return result
    }

    private static func formatSafetyExceededError(message: String, suggestion: String?) -> String {
        var result = "⛔️ Safety Limit Exceeded\n\n\(message)"

        if let suggestion = suggestion, !suggestion.isEmpty {
            result += "\n\n💡 Safer option: \(suggestion)"
        } else {
            result += "\n\nThis operation could cause data loss or system damage and cannot be automated for your safety. Please perform this action manually if you're certain it's needed."
        }

        return result
    }
}
