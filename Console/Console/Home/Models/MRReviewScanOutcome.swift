import Foundation

enum MRReviewScanTrigger: Equatable, Sendable {
    case manual, background
}

/// Status only: never includes source content or provider output.
enum MRReviewScanOutcome: Equatable, Sendable {
    case refreshed(Int)
    case unconfigured, signInRequired, deferred, alreadyRefreshing
    case unsupportedPage, failed, timedOut, cancelled

    var message: String {
        switch self {
        case .refreshed(let count): return "Checked GitLab: \(count) merge requests."
        case .unconfigured: return "Set a valid GitLab review list URL in Settings."
        case .signInRequired: return "Open GitLab to complete sign-in, then refresh."
        case .deferred: return "Background check deferred while browsing GitLab. Use Refresh to check the list."
        case .alreadyRefreshing: return "A GitLab check is already running."
        case .unsupportedPage: return "Could not identify the review list. Open GitLab and check the configured URL."
        case .failed: return "Could not read GitLab. Open GitLab or retry Refresh."
        case .timedOut: return "GitLab check timed out. Check your connection or sign-in, then refresh."
        case .cancelled: return "GitLab check cancelled. Refresh to retry."
        }
    }

    var succeeded: Bool {
        if case .refreshed = self { return true }
        return false
    }
}
