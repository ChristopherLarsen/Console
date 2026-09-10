import Foundation
import WebKit

/// A prepared launch: automatic local display name. Source metadata stays
/// local.
struct SessionDraft: Equatable {
    let purpose: SessionPurpose
    let source: SessionLaunchSource?
    var name: String
}

/// Actionable failure from a contextual launch. Views present `message` and,
/// when `offersSettingsRoute` is true, a control that opens Settings.
struct SessionLaunchFailure: Equatable {
    let message: String
    let offersSettingsRoute: Bool

    init(message: String, offersSettingsRoute: Bool) {
        self.message = message
        self.offersSettingsRoute = offersSettingsRoute
    }
}

/// Central launch entry point for intent-aware session creation. Builds
/// drafts from four intents, validates the single Session Folder
/// (Settings → Claude), creates sessions in it, and navigates to Sessions.
///
/// WebView-derived ticket/MR fields are local routing and display data.
/// Contextual launches open an idle session in the configured folder; they
/// never generate or send a source-derived prompt. The developer types work
/// context into Claude explicitly.
@MainActor
@Observable
final class SessionLaunchCoordinator {
    enum LaunchError: LocalizedError, Equatable {
        case sessionFolderMissing
        case sessionFolderUnavailable
        case sessionFolderNotAGitRepository

        var errorDescription: String? {
            switch self {
            case .sessionFolderMissing:
                return "Choose a Session Folder in Settings → Claude."
            case .sessionFolderUnavailable:
                return "The Session Folder is no longer available. Choose another in Settings → Claude."
            case .sessionFolderNotAGitRepository:
                return "Review sessions need a Git repository. Choose a Session Folder that contains a Git checkout in Settings → Claude."
            }
        }
    }

    /// Contextual-launch failure. MainView presents it.
    private(set) var lastFailure: SessionLaunchFailure?
    /// Shown when an editing launch would share a live checkout. Continue is
    /// required; Focus selects an occupant and launches nothing.
    private(set) var pendingCollision: PendingSharedCheckoutWarning?
    /// True while the shared-checkout warning sheet should be visible.
    private(set) var presentsCollisionSheet = false

    var lastFailureMessage: String? { lastFailure?.message }

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let workspaceStore: SessionWorkspaceStore
    @ObservationIgnored private let gitInspector: any LocalGitInspecting
    @ObservationIgnored private let recheckGate: (@MainActor () async -> Void)?
    /// Canonical paths claimed by in-flight launches or pending warnings so
    /// two simultaneous requests cannot both skip the occupancy check.
    @ObservationIgnored private var occupancyClaims: [UUID: String] = [:]

    init(
        store: SessionStore,
        workspaceStore: SessionWorkspaceStore,
        gitInspector: (any LocalGitInspecting)? = nil,
        recheckGate: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.workspaceStore = workspaceStore
        self.gitInspector = gitInspector ?? LocalGitWorkingCopyInspector()
        self.recheckGate = recheckGate
    }

    // MARK: - Drafts

    func draft(purpose: SessionPurpose, source: SessionLaunchSource?) -> SessionDraft {
        SessionDraft(
            purpose: purpose,
            source: source,
            name: purpose.defaultName(source: source)
        )
    }

    /// The current automatic name for a draft (used as the Customize
    /// placeholder and to regenerate after the source changes).
    func refreshedName(for draft: SessionDraft) -> String {
        draft.purpose.defaultName(source: draft.source)
    }

    // MARK: - Retained-page pre-population

    /// Source parsed from the retained Jira WebView's current URL, if it is
    /// displaying an issue. Memory-only; nothing is fetched. Used to name
    /// the local session — never sent to Claude.
    func retainedJiraSource() -> SessionLaunchSource? {
        guard let url = JiraWebSession.shared.page.url,
              let key = JiraSourceContext.parseIssueKey(fromURL: url) else {
            return nil
        }
        return .jira(key: key, title: JiraWebSession.shared.page.title, url: url)
    }

    /// Source parsed from whichever retained page (To Review or My list) is
    /// currently displaying a merge request.
    /// Memory-only; nothing is fetched.
    func retainedMergeRequestSource() -> SessionLaunchSource? {
        let store = CodeHostWebSessionStore.shared
        for page in [store.reviewsPage, store.authoredPage] {
            guard !page.isLoading, let url = page.url else { continue }
            if let source = MergeRequestSourceContext.launchSource(forURL: url, pageTitle: page.title) {
                return source
            }
        }
        return nil
    }

    // MARK: - Typed entry points for browser toolbars / future cards

    /// `displayName` overrides the automatic key-based session name. Home's
    /// new-ticket card passes the new-ticket rule (`NMA-1234` → `S-1234`);
    /// Jira-panel launches keep the automatic key name.
    func beginJiraTicketLaunch(key: String, title: String?, url: URL?, displayName: String? = nil) async {
        let source = SessionLaunchSource.jira(key: key, title: title, url: url)
        var prepared = draft(purpose: .existingTicket, source: source)
        if let displayName { prepared.name = displayName }
        await startContextualLaunch(prepared)
    }

    func beginMergeRequestReview(iid: String, title: String?, url: URL) async {
        let source = SessionLaunchSource.mergeRequest(iid: iid, title: title, url: url)
        await startContextualLaunch(draft(purpose: .review, source: source))
    }

    // MARK: - Launch

    /// Validates the Session Folder and launches. Returns the new session
    /// ID, or nil when a shared-checkout warning is now pending at MainView.
    ///
    /// Does not record `lastFailure` — the intent picker surfaces thrown
    /// errors itself. Contextual toolbar/card launches go through
    /// `startContextualLaunch`.
    @discardableResult
    func launch(draft: SessionDraft) async throws -> UUID? {
        lastFailure = nil
        clearCollision(releasingClaim: true)

        let folder = try validatedSessionFolder(purpose: draft.purpose)
        return try await performLaunch(draft: draft, folder: folder)
    }

    /// The single Session Folder, validated for this purpose. Refuses —
    /// never silently falls back to another directory — when unset,
    /// unavailable, or (for reviews) not a Git repository.
    private func validatedSessionFolder(purpose: SessionPurpose) throws -> SessionWorkspace {
        guard let folder = workspaceStore.defaultFolder else {
            throw LaunchError.sessionFolderMissing
        }
        guard workspaceStore.isAvailable(folder) else {
            throw LaunchError.sessionFolderUnavailable
        }
        if purpose == .review, !SessionWorkspaceStore.isGitRepository(atPath: folder.directoryPath) {
            throw LaunchError.sessionFolderNotAGitRepository
        }
        return folder
    }

    /// Focuses a live occupant and launches nothing.
    func focusExistingSession() {
        guard let pending = pendingCollision,
              let targetID = pending.focusedOccupantID,
              pending.liveOccupants.contains(where: { $0.id == targetID }) else {
            return
        }
        store.select(sessionID: targetID)
        ConsoleNavigation.showSessions()
        lastFailure = nil
        clearCollision(releasingClaim: true)
    }

    /// Explicit acknowledgement: launch in the same checkout without
    /// resetting, stashing, switching branches, or stopping occupants.
    @discardableResult
    func continueInSameFolder() async throws -> UUID? {
        guard let pending = pendingCollision else { return nil }
        lastFailure = nil
        do {
            return try await performLaunch(
                draft: pending.draft,
                folder: validatedSessionFolder(purpose: pending.draft.purpose),
                acknowledgeSharedCheckout: true,
                existingClaimID: pending.claimID
            )
        } catch {
            lastFailure = SessionLaunchFailure(error: error)
            throw error
        }
    }

    func cancelSharedCheckoutWarning() {
        lastFailure = nil
        clearCollision(releasingClaim: true)
    }

    func updatePendingCollisionOccupant(_ occupantID: UUID?) {
        guard var pending = pendingCollision else { return }
        pending.selectedOccupantID = occupantID
        pendingCollision = pending
    }

    func clearFailure() {
        lastFailure = nil
    }

    /// Opens Settings so the user can fix the Claude executable or the
    /// Session Folder.
    func openSessionsSettings() {
        presentsCollisionSheet = false
        lastFailure = nil
        ConsoleNavigation.showSettings()
    }

    /// Re-shows the shared-checkout warning after a Settings visit if the
    /// user never cancelled.
    func restoreCollisionSheetIfNeeded() {
        guard pendingCollision != nil else { return }
        presentsCollisionSheet = true
    }

    private func startContextualLaunch(_ draft: SessionDraft) async {
        do {
            _ = try await launch(draft: draft)
        } catch {
            lastFailure = SessionLaunchFailure(error: error)
        }
    }

    private func performLaunch(
        draft: SessionDraft,
        folder: SessionWorkspace,
        acknowledgeSharedCheckout: Bool = false,
        existingClaimID: UUID? = nil
    ) async throws -> UUID? {
        let canonicalPath = CheckoutPath.canonical(folder.directoryURL)

        let claimID = existingClaimID ?? UUID()
        if existingClaimID == nil {
            occupancyClaims[claimID] = canonicalPath
        }
        var created = false
        defer {
            if !created, pendingCollision?.claimID != claimID {
                occupancyClaims.removeValue(forKey: claimID)
            }
        }

        if let recheckGate {
            await recheckGate()
        }

        if !acknowledgeSharedCheckout,
           let warning = await warningIfOccupied(
            draft: draft,
            canonicalPath: canonicalPath,
            claimID: claimID
           ) {
            presentCollision(warning)
            return nil
        }

        // Recheck immediately before create so two overlapping launches
        // cannot both observe an empty occupant list and skip the warning.
        if !acknowledgeSharedCheckout,
           let warning = await warningIfOccupied(
            draft: draft,
            canonicalPath: canonicalPath,
            claimID: claimID
           ) {
            presentCollision(warning)
            return nil
        }

        let request = SessionCreationRequest(
            purpose: draft.purpose,
            name: draft.name,
            workingDirectory: folder.directoryURL,
            source: draft.source
        )

        let sessionID = try store.createSession(request: request)
        created = true
        occupancyClaims.removeValue(forKey: claimID)

        lastFailure = nil
        clearCollision(releasingClaim: false)
        ConsoleNavigation.showSessions()
        return sessionID
    }

    private func warningIfOccupied(
        draft: SessionDraft,
        canonicalPath: String,
        claimID: UUID
    ) async -> PendingSharedCheckoutWarning? {
        let first = occupancy(canonicalPath: canonicalPath, excludingClaim: claimID)
        guard first.hasConflict else { return nil }
        let gitState = await gitInspector.inspect(canonicalPath: canonicalPath)
        let second = occupancy(canonicalPath: canonicalPath, excludingClaim: claimID)
        guard second.hasConflict else { return nil }
        return PendingSharedCheckoutWarning(
            id: UUID(),
            claimID: claimID,
            draft: draft,
            canonicalPath: canonicalPath,
            occupants: second.occupants,
            gitState: gitState,
            selectedOccupantID: second.occupants.first(where: \.isLiveSession)?.id
        )
    }

    private func occupancy(
        canonicalPath: String,
        excludingClaim claimID: UUID
    ) -> SharedCheckoutOccupancy {
        let live = store.liveEditingSessions(occupyingCanonicalPath: canonicalPath)
        let otherClaimIDs = occupancyClaims.compactMap { id, path -> UUID? in
            guard id != claimID, path == canonicalPath else { return nil }
            return id
        }
        return SharedCheckoutOccupancy(live: live, otherClaimIDs: otherClaimIDs)
    }

    private func presentCollision(_ warning: PendingSharedCheckoutWarning) {
        if let existing = pendingCollision, existing.claimID != warning.claimID {
            occupancyClaims.removeValue(forKey: existing.claimID)
        }
        pendingCollision = warning
        presentsCollisionSheet = true
        lastFailure = nil
    }

    private func clearCollision(releasingClaim: Bool) {
        if releasingClaim, let pending = pendingCollision {
            occupancyClaims.removeValue(forKey: pending.claimID)
        }
        pendingCollision = nil
        presentsCollisionSheet = false
    }

    #if DEBUG
    /// UI-test seam: present a synthetic launch failure without touching
    /// workspaces, Claude, or UserDefaults.
    func debugPresentSyntheticFailure() {
        lastFailure = SessionLaunchFailure(error: SessionCreationError.claudeNotFound)
    }
    #endif
}

extension SessionLaunchFailure {
    init(error: Error) {
        if let launchError = error as? SessionLaunchCoordinator.LaunchError {
            self.init(message: launchError.localizedDescription, offersSettingsRoute: true)
            return
        }
        if let creation = error as? SessionCreationError {
            switch creation {
            case .claudeNotFound:
                self.init(message: creation.localizedDescription, offersSettingsRoute: true)
            case .pluginAssemblyFailed:
                self.init(message: creation.localizedDescription, offersSettingsRoute: false)
            case .sessionLaunchFailed:
                self.init(message: creation.localizedDescription, offersSettingsRoute: true)
            }
            return
        }
        self.init(message: error.localizedDescription, offersSettingsRoute: true)
    }
}

private struct SharedCheckoutOccupancy {
    let live: [ConsoleSession]
    let otherClaimIDs: [UUID]

    var hasConflict: Bool { !live.isEmpty || !otherClaimIDs.isEmpty }

    var occupants: [SharedCheckoutOccupant] {
        var result = live.map { session in
            SharedCheckoutOccupant(
                id: session.id,
                name: session.name,
                purpose: session.purpose,
                isLiveSession: true
            )
        }
        if result.isEmpty {
            result.append(contentsOf: otherClaimIDs.map(SharedCheckoutOccupant.inFlightPlaceholder(claimID:)))
        }
        return result
    }
}
