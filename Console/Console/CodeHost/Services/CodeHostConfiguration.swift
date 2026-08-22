import Foundation

/// Host-neutral URL resolution: returns the effective list URL for the given
/// provider and list kind. Each host keeps its own preference keys, so
/// switching hosts never overwrites or clears the other host's configuration.
enum CodeHostConfiguration {
    static func effectiveURLString(
        for kind: CodeHostListKind,
        provider: CodeHostProvider,
        defaults: UserDefaults = .standard
    ) -> String {
        switch (provider, kind) {
        case (.gitlab, .reviewsRequested):
            return GitLabConfiguration.effectiveReviewsURLString(defaults: defaults)
        case (.gitlab, .authored):
            return GitLabConfiguration.effectiveAuthoredURLString(defaults: defaults)
        case (.github, .reviewsRequested):
            return GitHubConfiguration.effectiveReviewsURLString(defaults: defaults)
        case (.github, .authored):
            return GitHubConfiguration.effectiveAuthoredURLString(defaults: defaults)
        }
    }

    static func effectiveURLString(for kind: CodeHostListKind) -> String {
        effectiveURLString(for: kind, provider: AppSettings().codeHostProvider)
    }
}
