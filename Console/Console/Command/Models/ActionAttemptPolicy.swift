import Foundation

/// Pure per-action attempt policy for command execution.
///
/// ## `retryOnFailure` (default off)
/// Retry is never inferred. Non-idempotent commands run once unless the saved
/// action explicitly sets `retryOnFailure` to `true`.
///
/// ## Meaning of `maxRetries`
/// When retry is enabled, `maxRetries` is the **total number of primary
/// attempts** (the first try plus retries). It is not an extra-retry count.
/// A value of `3` means up to three primary executions. Fallback, if present,
/// is not counted in this number.
///
/// ## Normalization (runtime)
/// Applied only when `retryOnFailure` is `true`:
/// - `nil` → `3`
/// - `<= 0` → `1` (retry flag is kept, but there is no extra attempt)
/// - `1...10` → as given
/// - `> 10` → `10` (hard cap)
///
/// When `retryOnFailure` is `false`, primary attempts is always `1` and
/// `maxRetries` is ignored.
///
/// Saving rejects negative and over-cap values (`retryLimitValidationMessage`).
/// Zero is allowed at save time and normalized to `1` at runtime.
///
/// ## Fallback
/// Eligible only after every primary attempt has failed. Callers must not run
/// a fallback after cancellation; ``shouldRunFallback(primarySucceeded:isCancelled:)``
/// is `false` when `isCancelled` is true.
struct ActionAttemptPolicy: Equatable, Sendable {
    static let defaultPrimaryAttempts = 3
    static let maxPrimaryAttempts = 10

    let retryEnabled: Bool
    let primaryAttemptCount: Int
    let hasFallback: Bool

    init(retryOnFailure: Bool, maxRetries: Int?, hasFallback: Bool) {
        retryEnabled = retryOnFailure
        self.hasFallback = hasFallback
        if retryOnFailure {
            primaryAttemptCount = Self.normalize(maxRetries)
        } else {
            primaryAttemptCount = 1
        }
    }

    init(action: CommandAction) {
        self.init(
            retryOnFailure: action.retryOnFailure,
            maxRetries: action.maxRetries,
            hasFallback: action.fallbackAction != nil
        )
    }

    /// Clamp a stored `maxRetries` to the documented runtime range.
    static func normalize(_ maxRetries: Int?) -> Int {
        guard let maxRetries else { return defaultPrimaryAttempts }
        if maxRetries < 1 { return 1 }
        if maxRetries > maxPrimaryAttempts { return maxPrimaryAttempts }
        return maxRetries
    }

    /// Reject values that should not be saved. `nil` and `0` are allowed;
    /// `0` is normalized to `1` at runtime.
    static func retryLimitValidationMessage(retryOnFailure: Bool, maxRetries: Int?) -> String? {
        guard retryOnFailure, let maxRetries else { return nil }
        if maxRetries < 0 {
            return "maxRetries must be ≥ 0 (nil defaults to \(defaultPrimaryAttempts))"
        }
        if maxRetries > maxPrimaryAttempts {
            return "maxRetries must be ≤ \(maxPrimaryAttempts) (got \(maxRetries))"
        }
        return nil
    }

    func shouldRunFallback(primarySucceeded: Bool, isCancelled: Bool) -> Bool {
        hasFallback && !primarySucceeded && !isCancelled
    }
}

enum ActionAttemptError: LocalizedError {
    case exhausted(attempts: Int, underlying: Error)
    case fallbackFailed(attempts: Int, underlying: Error)
    case invalidFallback(String)

    var errorDescription: String? {
        switch self {
        case .exhausted(let attempts, let underlying):
            return "Failed after \(attempts) attempt(s): \(underlying.localizedDescription)"
        case .fallbackFailed(let attempts, let underlying):
            return "Fallback failed after \(attempts) primary attempt(s): \(underlying.localizedDescription)"
        case .invalidFallback(let message):
            return "Fallback is invalid: \(message)"
        }
    }
}
