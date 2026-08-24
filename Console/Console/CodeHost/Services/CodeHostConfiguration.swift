import Foundation

/// Host-neutral URL resolution: returns the effective list URL for the given
/// list kind, backed by the GitLab preference keys.
enum CodeHostConfiguration {
    static func effectiveURLString(
        for kind: CodeHostListKind,
        defaults: UserDefaults = .standard
    ) -> String {
        switch kind {
        case .reviewsRequested:
            return GitLabConfiguration.effectiveReviewsURLString(defaults: defaults)
        case .authored:
            return GitLabConfiguration.effectiveAuthoredURLString(defaults: defaults)
        }
    }
}
