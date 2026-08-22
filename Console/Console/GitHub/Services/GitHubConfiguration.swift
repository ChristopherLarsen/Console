import Foundation

/// Resolves the configured GitHub list URLs for the shared panels.
///
/// Values are user-configured exact list URLs (for example the github.com
/// review-requested dashboard); Console never builds query parameters and
/// never logs them.
enum GitHubConfiguration {

    /// Exact reviews-requested list URL string, or "" when unconfigured.
    static func effectiveReviewsURLString(defaults: UserDefaults = .standard) -> String {
        sanitized(
            defaults.string(forKey: AppSettings.webViewGitHubReviewsURLKey)
        )
    }

    /// Exact authored-PR list URL string, or "" when unconfigured.
    static func effectiveAuthoredURLString(defaults: UserDefaults = .standard) -> String {
        sanitized(
            defaults.string(forKey: AppSettings.webViewGitHubMyPullRequestsURLKey)
        )
    }

    private static func sanitized(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
