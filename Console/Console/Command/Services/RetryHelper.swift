import Foundation

enum RetryHelper {
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0,
        retryableCheck: ((Error) -> Bool)? = nil,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = initialDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                let shouldRetry = retryableCheck?(error) ?? isRetryable(error)
                if !shouldRetry || attempt == maxAttempts {
                    throw error
                }

                try await Task.sleep(for: .seconds(delay))
                delay *= backoffMultiplier
            }
        }

        throw lastError ?? LLMGeneratorError.apiError("Retry exhausted")
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let llmError = error as? LLMGeneratorError {
            switch llmError {
            case .apiError(let message):
                let lower = message.lowercased()
                if lower.contains("rate limit") || lower.contains("429") { return true }
                if lower.contains("500") || lower.contains("502") || lower.contains("503") { return true }
                if lower.contains("timeout") { return true }
                return false
            case .networkError:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }
}
