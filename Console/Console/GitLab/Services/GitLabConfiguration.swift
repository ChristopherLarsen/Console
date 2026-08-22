import Foundation

/// Resolves the configured GitLab list URLs for the shared panels.
///
/// Conservative migration: each new key is preferred; only the reviews list
/// may fall back to the legacy generic Merge Requests URL when its own key is
/// empty. New keys are never written back and the legacy key is never deleted
/// or overwritten. Configured URLs are never logged.
enum GitLabConfiguration {

    /// Exact reviews-requested list URL string, or "" when unconfigured.
    static func effectiveReviewsURLString(defaults: UserDefaults = .standard) -> String {
        let configured = sanitized(
            defaults.string(forKey: AppSettings.webViewGitLabReviewsURLKey)
        )
        if !configured.isEmpty { return configured }

        // Legacy fallback: the old generic Merge Requests sidebar value.
        return sanitized(
            defaults.string(forKey: AppSettings.webViewMergeRequestsURLLegacyKey)
        )
    }

    /// Exact authored-MR list URL string, or "" when unconfigured.
    static func effectiveAuthoredURLString(defaults: UserDefaults = .standard) -> String {
        sanitized(
            defaults.string(forKey: AppSettings.webViewGitLabMyMergeRequestsURLKey)
        )
    }

    private static func sanitized(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
