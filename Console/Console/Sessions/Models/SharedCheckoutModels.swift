import Foundation

/// Symlink-resolved, standardized directory path used to decide whether two
/// sessions share one working copy. Linked worktrees keep distinct paths
/// even when they share a repository.
enum CheckoutPath {
    static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// What a launch will do: create a session, or resume one from a
/// restoration record.
enum PendingLaunchAction: Equatable {
    case create(request: SessionCreationRequest)
    case resume(record: SessionRestorationRecord)
}
