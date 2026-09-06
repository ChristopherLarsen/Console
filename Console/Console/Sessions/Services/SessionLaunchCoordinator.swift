import Foundation
import WebKit

/// A prepared launch: automatic local display name and an optional explicit
/// workspace. Views may edit name/workspaceID before handing the draft back
/// to the coordinator's `launch(draft:)`. Source metadata stays local.
struct SessionDraft {
    let purpose: SessionPurpose
    let source: SessionLaunchSource?
    var name: String
    var workspaceID: UUID?
}

/// One launch awaiting its one-time workspace choice. Hosted as a sheet at
/// MainView so Jira, GitLab, Home cards, and Sessions share one flow.
/// `selectedWorkspaceID` is kept across failed Start attempts and a Settings
/// round-trip so retry does not lose the folder.
struct PendingWorkspaceChoice: Identifiable, Equatable {
    let id: UUID
    let purpose: SessionPurpose
    let name: String
    let source: SessionLaunchSource?
    var selectedWorkspaceID: UUID?

    init(
        purpose: SessionPurpose,
        name: String,
        source: SessionLaunchSource?,
        selectedWorkspaceID: UUID? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.purpose = purpose
        self.name = name
        self.source = source
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}

/// Actionable failure from a contextual launch or chooser Start. Views
/// present `message` and, when `offersSettingsRoute` is true, a control
/// that opens Settings → Sessions / Claude Executable.
struct SessionLaunchFailure: Equatable {
    let message: String
    let offersSettingsRoute: Bool

    init(message: String, offersSettingsRoute: Bool) {
        self.message = message
        self.offersSettingsRoute = offersSettingsRoute
    }
}

/// Central launch entry point for intent-aware session creation. Builds
/// drafts from four intents, resolves workspaces through the documented
/// order, hosts unresolved choices at MainView, creates sessions, and
/// navigates to Sessions.
///
/// WebView-derived ticket/MR fields are local routing and display data.
/// Contextual launches may choose a folder and open an idle session; they
/// never generate or send a source-derived prompt. The developer types work
/// context into Claude explicitly.
///
/// Resolution order:
/// 1. Explicit workspace override (Customize).
/// 2. Remembered source-to-workspace association.
/// 3. For merge-request reviews, a unique remote match for the MR project.
/// 4. For New Ticket / General, the selected session's containing workspace.
/// 5. Last workspace used for that purpose.
/// 6. Global default workspace.
/// 7. Ask once and remember.
@MainActor
@Observable
final class SessionLaunchCoordinator {
    enum LaunchError: LocalizedError, Equatable {
        case workspaceUnavailable
        case workspaceNotAGitRepository

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                return "That workspace folder is no longer available. Choose another in Settings → Sessions."
            case .workspaceNotAGitRepository:
                return "Review sessions need a Git repository. Choose a folder that contains a Git checkout, or add one in Settings → Sessions."
            }
        }
    }

    private(set) var pendingChoice: PendingWorkspaceChoice?
    /// True while the one-time chooser sheet should be visible. Cleared when
    /// opening Settings so the sheet does not cover the destination; restored
    /// when the user leaves Settings if the draft is still pending.
    private(set) var presentsChoiceSheet = false
    /// Contextual-launch / chooser-Start failure. MainView presents it when
    /// the chooser is hidden; the chooser presents it while the sheet is up.
    private(set) var lastFailure: SessionLaunchFailure?

    var lastFailureMessage: String? { lastFailure?.message }

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let workspaceStore: SessionWorkspaceStore
    @ObservationIgnored private let resolver: RepositoryIdentityResolver

    init(store: SessionStore, workspaceStore: SessionWorkspaceStore) {
        self.store = store
        self.workspaceStore = workspaceStore
        self.resolver = RepositoryIdentityResolver()
    }

    // MARK: - Drafts

    func draft(purpose: SessionPurpose, source: SessionLaunchSource?) -> SessionDraft {
        SessionDraft(
            purpose: purpose,
            source: source,
            name: purpose.defaultName(source: source),
            workspaceID: nil
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
    /// the local session and route a workspace — never sent to Claude.
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

    func beginJiraTicketLaunch(key: String, title: String?, url: URL?) {
        let source = SessionLaunchSource.jira(key: key, title: title, url: url)
        startContextualLaunch(draft(purpose: .existingTicket, source: source))
    }

    func beginMergeRequestReview(iid: String, title: String?, url: URL) {
        let source = SessionLaunchSource.mergeRequest(iid: iid, title: title, url: url)
        startContextualLaunch(draft(purpose: .review, source: source))
    }

    // MARK: - Launch

    /// Resolves and launches a draft. Returns the new session ID, or nil when
    /// a one-time workspace choice is now pending at MainView.
    ///
    /// Does not record `lastFailure` — the intent picker surfaces thrown
    /// errors itself. Contextual toolbar/card launches go through
    /// `startContextualLaunch`.
    @discardableResult
    func launch(draft: SessionDraft) throws -> UUID? {
        lastFailure = nil
        pendingChoice = nil
        presentsChoiceSheet = false

        // 1. Explicit override wins and skips association learning.
        if let overrideID = draft.workspaceID {
            return try performLaunch(draft: draft, workspaceID: overrideID, rememberingAssociation: false)
        }

        if let resolved = resolveWorkspace(purpose: draft.purpose, source: draft.source) {
            return try performLaunch(draft: draft, workspaceID: resolved.id, rememberingAssociation: true)
        }

        // 7. Ask once and remember.
        pendingChoice = PendingWorkspaceChoice(
            purpose: draft.purpose,
            name: draft.name,
            source: draft.source,
            selectedWorkspaceID: draft.workspaceID
        )
        presentsChoiceSheet = true
        return nil
    }

    /// Confirms the one-time choice; the association is remembered so later
    /// launches of the same source are one click. The pending draft and
    /// selected folder stay until this succeeds or the user cancels.
    @discardableResult
    func confirmWorkspaceChoice(workspaceID: UUID) throws -> UUID? {
        guard var choice = pendingChoice else { return nil }
        choice.selectedWorkspaceID = workspaceID
        pendingChoice = choice
        lastFailure = nil

        let draft = SessionDraft(
            purpose: choice.purpose,
            source: choice.source,
            name: choice.name,
            workspaceID: workspaceID
        )
        do {
            return try performLaunch(draft: draft, workspaceID: workspaceID, rememberingAssociation: true)
        } catch {
            lastFailure = SessionLaunchFailure(error: error)
            throw error
        }
    }

    func cancelWorkspaceChoice() {
        pendingChoice = nil
        presentsChoiceSheet = false
        lastFailure = nil
    }

    func clearFailure() {
        lastFailure = nil
    }

    /// Hides the chooser without dropping the draft, then opens Settings so
    /// the user can fix the Claude executable or workspace folders.
    func openSessionsSettings() {
        presentsChoiceSheet = false
        lastFailure = nil
        ConsoleNavigation.showSettings()
    }

    /// Re-shows the chooser after a Settings visit if the user never cancelled.
    func restoreChoiceSheetIfNeeded() {
        guard pendingChoice != nil else { return }
        presentsChoiceSheet = true
    }

    func updatePendingWorkspaceSelection(_ workspaceID: UUID?) {
        guard var choice = pendingChoice else { return }
        choice.selectedWorkspaceID = workspaceID
        pendingChoice = choice
    }

    /// False when nothing is selected or the folder cannot host this purpose.
    func canConfirmWorkspace(workspaceID: UUID?, purpose: SessionPurpose) -> Bool {
        guard let workspaceID else { return false }
        return workspaceBlockingReason(workspaceID: workspaceID, purpose: purpose) == nil
    }

    /// User-facing reason Start is disabled, or nil when the folder is valid.
    func workspaceBlockingReason(workspaceID: UUID, purpose: SessionPurpose) -> String? {
        guard let workspace = workspaceStore.workspace(withID: workspaceID) else {
            return LaunchError.workspaceUnavailable.errorDescription
        }
        if !workspaceStore.isAvailable(workspace) {
            return LaunchError.workspaceUnavailable.errorDescription
        }
        if purpose == .review, !SessionWorkspaceStore.isGitRepository(atPath: workspace.directoryPath) {
            return LaunchError.workspaceNotAGitRepository.errorDescription
        }
        if !SessionWorkspaceStore.meetsRequirement(for: workspace, purpose: purpose) {
            return LaunchError.workspaceUnavailable.errorDescription
        }
        return nil
    }

    private func startContextualLaunch(_ draft: SessionDraft) {
        do {
            _ = try launch(draft: draft)
        } catch {
            lastFailure = SessionLaunchFailure(error: error)
        }
    }

    private func requireValidWorkspace(_ workspaceID: UUID, purpose: SessionPurpose) throws -> SessionWorkspace {
        guard let workspace = workspaceStore.workspace(withID: workspaceID) else {
            throw LaunchError.workspaceUnavailable
        }
        guard workspaceStore.isAvailable(workspace) else {
            throw LaunchError.workspaceUnavailable
        }
        if purpose == .review, !SessionWorkspaceStore.isGitRepository(atPath: workspace.directoryPath) {
            throw LaunchError.workspaceNotAGitRepository
        }
        guard SessionWorkspaceStore.meetsRequirement(for: workspace, purpose: purpose) else {
            throw LaunchError.workspaceUnavailable
        }
        return workspace
    }

    private func performLaunch(
        draft: SessionDraft,
        workspaceID: UUID,
        rememberingAssociation: Bool
    ) throws -> UUID {
        let workspace = try requireValidWorkspace(workspaceID, purpose: draft.purpose)

        let request = SessionCreationRequest(
            purpose: draft.purpose,
            name: draft.name,
            workingDirectory: workspace.directoryURL,
            source: draft.source
        )

        let sessionID = try store.createSession(request: request)

        if rememberingAssociation, let identity = draft.source?.routingIdentity {
            workspaceStore.rememberAssociation(routingIdentity: identity, workspaceID: workspaceID)
        }
        workspaceStore.noteUse(workspaceID: workspaceID, purpose: draft.purpose)

        lastFailure = nil
        pendingChoice = nil
        presentsChoiceSheet = false
        ConsoleNavigation.showSessions()
        return sessionID
    }

    private func resolveWorkspace(purpose: SessionPurpose, source: SessionLaunchSource?) -> SessionWorkspace? {
        // 2. Remembered association for this ticket/MR project.
        if let identity = source?.routingIdentity,
           let rememberedID = workspaceStore.associatedWorkspaceID(forRoutingIdentity: identity),
           let remembered = workspaceStore.workspace(withID: rememberedID),
           SessionWorkspaceStore.meetsRequirement(for: remembered, purpose: purpose) {
            return remembered
        }

        // 3. Unique code-host remote match for review sources.
        if case let .mergeRequest(_, _, url) = source,
           let identity = MergeRequestSourceContext.projectIdentity(inURL: url) {
            switch resolver.match(projectIdentity: identity, in: workspaceStore.resolvableWorkspaces(purpose: purpose)) {
            case let .unique(workspace):
                return workspace
            case .ambiguous, .none:
                break
            }
        }

        // 4. The selected session's containing workspace (New Ticket / General).
        if purpose == .newTicket || purpose == .general,
           let selectedDirectory = store.selectedSession?.workingDirectory,
           let containing = workspaceStore.availableWorkspaces.first(where: {
               SessionWorkspaceStore.contains($0, directory: selectedDirectory)
           }) {
            return containing
        }

        // 5. Last workspace used for this purpose.
        if let lastUsedID = workspaceStore.lastUsedWorkspaceID(for: purpose),
           let lastUsed = workspaceStore.workspace(withID: lastUsedID),
           SessionWorkspaceStore.meetsRequirement(for: lastUsed, purpose: purpose) {
            return lastUsed
        }

        // 6. Global default workspace.
        if let defaultID = workspaceStore.defaultWorkspaceID,
           let fallback = workspaceStore.workspace(withID: defaultID),
           SessionWorkspaceStore.meetsRequirement(for: fallback, purpose: purpose) {
            return fallback
        }

        return nil
    }

    #if DEBUG
    /// UI-test seam: present a synthetic launch failure without touching
    /// workspaces, Claude, or UserDefaults.
    func debugPresentSyntheticFailure() {
        lastFailure = SessionLaunchFailure(error: SessionCreationError.claudeNotFound)
        presentsChoiceSheet = false
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
            }
            return
        }
        self.init(message: error.localizedDescription, offersSettingsRoute: true)
    }
}
