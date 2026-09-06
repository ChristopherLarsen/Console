import Foundation

/// One-shot handoff telling the JIRA destination to land on a captured issue
/// URL instead of the configured list. Set right before switching the sidebar
/// selection; consumed by the destination's onAppear.
@MainActor
final class JiraDeepLink {
    static let shared = JiraDeepLink()

    private var pendingURL: URL?

    func set(url: URL) {
        pendingURL = url
    }

    /// Returns and clears the pending issue URL.
    func consume() -> URL? {
        let url = pendingURL
        pendingURL = nil
        return url
    }

    func reset() {
        pendingURL = nil
    }
}
