import Foundation

/// Extracts the HTTP status code from the `"[status] body"` apiError messages
/// produced by `LLMClient.performHTTPRequest`. Only a leading bracketed code is
/// authoritative — bare digit substrings elsewhere in the body are not.
enum LLMAPIStatus {
    static func fromAPIMessage(_ message: String) -> Int? {
        guard message.hasPrefix("["), let close = message.firstIndex(of: "]") else {
            return nil
        }
        let digits = message[message.index(after: message.startIndex)..<close]
        guard digits.count == 3, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Transient server/overload statuses worth retrying with backoff.
    static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
}

enum RetryHelper {
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0,
        retryableCheck: ((Error) -> Bool)? = nil,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withRetryReportingAttempts(
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            backoffMultiplier: backoffMultiplier,
            retryableCheck: retryableCheck,
            operation: operation
        ).value
    }

    /// Same retry policy as `withRetry`, but reports how many attempts were
    /// actually performed so failure reports do not have to hardcode the max.
    /// `recordAttempt` fires after every attempt, including the failing one.
    static func withRetryReportingAttempts<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0,
        retryableCheck: ((Error) -> Bool)? = nil,
        recordAttempt: ((Int) -> Void)? = nil,
        operation: @escaping () async throws -> T
    ) async throws -> (value: T, attempts: Int) {
        var lastError: Error?
        var delay = initialDelay

        for attempt in 1...maxAttempts {
            do {
                recordAttempt?(attempt)
                return (try await operation(), attempt)
            } catch {
                lastError = error
                recordAttempt?(attempt)

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
                // A leading bracketed status is the authoritative HTTP result;
                // never classify by digit substrings elsewhere in the body.
                if let status = LLMAPIStatus.fromAPIMessage(message) {
                    return LLMAPIStatus.retryableStatuses.contains(status)
                }
                let lower = message.lowercased()
                if lower.contains("rate limit") { return true }
                if lower.contains("timeout") { return true }
                if lower.contains("overloaded") { return true }
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
