import Foundation

/// One-shot handoff telling the MergeRequests destination to land on a
/// specific merge request instead of the configured list. Set right before
/// switching the sidebar selection; consumed by the destination's onAppear.
@MainActor
final class MergeRequestDeepLink {
    static let shared = MergeRequestDeepLink()

    private var pendingURL: URL?
    private var pendingKind: CodeHostListKind?

    func set(url: URL, kind: CodeHostListKind) {
        set(url: Optional.some(url), kind: kind)
    }

    /// Selects the list segment. A nil URL opens the source list rather than
    /// a specific merge request.
    func set(url: URL?, kind: CodeHostListKind) {
        pendingURL = url
        pendingKind = kind
    }

    /// Returns and clears the pending URL when it targets `kind`.
    func consume(matching kind: CodeHostListKind) -> URL? {
        guard pendingKind == kind, let url = pendingURL else { return nil }
        pendingURL = nil
        pendingKind = nil
        return url
    }

    /// Peeks at the targeted list without consuming anything; used to pick
    /// the destination's initially visible segment.
    func consumeKindHint() -> CodeHostListKind? {
        pendingKind
    }

    func reset() {
        pendingURL = nil
        pendingKind = nil
    }
}
