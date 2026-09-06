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

/// Read-only Git branch / dirty snapshot for the shared-checkout warning.
/// Never includes remotes, URLs, or ticket/MR text.
struct LocalGitWorkingCopyState: Equatable, Sendable {
    var isRepository: Bool
    var isAvailable: Bool
    var branchName: String?
    var isDetached: Bool
    var isDirty: Bool

    static let unavailable = LocalGitWorkingCopyState(
        isRepository: false,
        isAvailable: false,
        branchName: nil,
        isDetached: false,
        isDirty: false
    )

    static let notARepository = LocalGitWorkingCopyState(
        isRepository: false,
        isAvailable: true,
        branchName: nil,
        isDetached: false,
        isDirty: false
    )

    static func fixture(branch: String = "main", isDirty: Bool = true) -> LocalGitWorkingCopyState {
        LocalGitWorkingCopyState(
            isRepository: true,
            isAvailable: true,
            branchName: branch,
            isDetached: false,
            isDirty: isDirty
        )
    }

    var branchDisplay: String {
        if !isAvailable { return "Git status unavailable" }
        if !isRepository { return "Not a Git repository" }
        if isDetached {
            if let branchName, !branchName.isEmpty {
                return "Detached HEAD (\(branchName))"
            }
            return "Detached HEAD"
        }
        return branchName ?? "Unknown branch"
    }

    var workingTreeDisplay: String {
        if !isAvailable || !isRepository { return "" }
        return isDirty ? "Uncommitted local changes" : "Working tree clean"
    }
}

/// A live session (or in-flight launch) occupying a checkout.
struct SharedCheckoutOccupant: Identifiable, Equatable {
    let id: UUID
    let name: String
    let purpose: SessionPurpose?
    let isLiveSession: Bool

    static func inFlightPlaceholder(claimID: UUID) -> SharedCheckoutOccupant {
        SharedCheckoutOccupant(
            id: claimID,
            name: "Another session is starting",
            purpose: nil,
            isLiveSession: false
        )
    }
}

/// One launch waiting on Focus / Continue / Cancel because the checkout is
/// already occupied. Hosted as a sheet at MainView.
struct PendingSharedCheckoutWarning: Identifiable, Equatable {
    let id: UUID
    let claimID: UUID
    let draft: SessionDraft
    let workspaceID: UUID
    let rememberingAssociation: Bool
    let canonicalPath: String
    var occupants: [SharedCheckoutOccupant]
    var gitState: LocalGitWorkingCopyState
    var selectedOccupantID: UUID?

    var liveOccupants: [SharedCheckoutOccupant] {
        occupants.filter(\.isLiveSession)
    }

    var canFocusExisting: Bool {
        liveOccupants.contains { $0.id == (selectedOccupantID ?? liveOccupants.first?.id) }
    }

    var focusedOccupantID: UUID? {
        let selected = selectedOccupantID ?? liveOccupants.first?.id
        guard let selected, liveOccupants.contains(where: { $0.id == selected }) else {
            return liveOccupants.first?.id
        }
        return selected
    }
}
