import Foundation

/// Which code host Console targets. Only one host is active at a time; the
/// user can switch between them at any time from Settings. The inactive
/// host's configuration and WebKit session are preserved untouched.
enum CodeHostProvider: String, CaseIterable, Identifiable, Sendable {
    case gitlab
    case github

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gitlab: return "GitLab"
        case .github: return "GitHub"
        }
    }

    /// Prefix for automatic review session names, followed by the MR IID or
    /// PR number (`Review !42`, `Review #42`).
    var reviewNamePrefix: String {
        switch self {
        case .gitlab: return "Review !"
        case .github: return "Review #"
        }
    }
}
