import Foundation
import WebKit

/// A prepared launch: automatic name, generated starter prompt, and an
/// optional explicit workspace. Views may edit name/workspaceID before
/// handing the draft back to the coordinator's `launch(draft:)`.
struct SessionDraft {
    let purpose: SessionPurpose
    let source: SessionLaunchSource?
    let starterPrompt: String?
    var name: String
    var workspaceID: UUID?
}

/// One launch awaiting its one-time workspace choice. Hosted as a sheet at
/// MainView so Jira, GitLab, Home cards, and Sessions share one flow.
struct PendingWorkspaceChoice: Identifiable {
    let id = UUID()
    let purpose: SessionPurpose
    let name: String
    let source: SessionLaunchSource?
    let starterPrompt: String?
}

/// Central launch entry point for intent-aware session creation. Builds
/// drafts from four intents, resolves workspaces through the documented
/// order, hosts unresolved choices at MainView, creates sessions, navigates
/// to Sessions, and delivers memory-only starter prompts.
///
/// Resolution order:
/// 1. Explicit workspace override (Customize).
/// 2. Remembered source-to-workspace association.
/// 3. For GitLab reviews, a unique remote match for the MR project.
/// 4. For New Ticket / General, the selected session's containing workspace.
/// 5. Last workspace used for that purpose.
/// 6. Global default workspace.
/// 7. Ask once and remember.
@MainActor
@Observable
final class SessionLaunchCoordinator {
    enum LaunchError: LocalizedError {
        case workspaceUnavailable

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                return "That workspace folder is no longer available. Choose another in Settings → Sessions."
            }
        }
    }

    private(set) var pendingChoice: PendingWorkspaceChoice?
    /// Set when a contextual launch failed after a workspace was chosen;
    /// surfaced by MainView and cleared on dismissal.
    private(set) var lastFailureMessage: String?

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let workspaceStore: SessionWorkspaceStore
    @ObservationIgnored private let resolver: RepositoryIdentityResolver

    init(store: SessionStore, workspaceStore: SessionWorkspaceStore) {
        self.store = store
        self.workspaceStore = workspaceStore
        self.resolver = RepositoryIdentityResolver()

        // Deliver queued starter prompts exactly once, at sessionStarted.
        store.lifecycleObserver = { [weak self] sessionID, event in
            self?.handleLifecycleEvent(sessionID: sessionID, event: event)
        }
    }

    // MARK: - Drafts

    func draft(purpose: SessionPurpose, source: SessionLaunchSource?) -> SessionDraft {
        SessionDraft(
            purpose: purpose,
            source: source,
            starterPrompt: StarterPromptBuilder.prompt(for: purpose, source: source),
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
    /// displaying an issue. Memory-only; nothing is fetched.
    func retainedJiraSource() -> SessionLaunchSource? {
        guard let url = JiraWebSession.shared.page.url,
              let key = JiraSourceContext.parseIssueKey(fromURL: url) else {
            return nil
        }
        return .jira(key: key, title: JiraWebSession.shared.page.title, url: url)
    }

    /// Source parsed from whichever retained GitLab page (To Review or My MRs)
    /// is currently displaying a merge request. Memory-only; nothing is fetched.
    func retainedMergeRequestSource() -> SessionLaunchSource? {
        let pages = [
            GitLabWebSessionStore.shared.reviewsPage,
            GitLabWebSessionStore.shared.authoredPage,
        ]
        for page in pages {
            guard let url = page.url,
                  let info = GitLabSourceContext.parseMergeRequest(fromURL: url) else {
                continue
            }
            return .gitLabMergeRequest(iid: info.iid, title: page.title, url: url)
        }
        return nil
    }

    // MARK: - Typed entry points for browser toolbars / future cards

    func beginJiraTicketLaunch(key: String, title: String?, url: URL?) {
        let source = SessionLaunchSource.jira(key: key, title: title, url: url)
        startContextualLaunch(draft(purpose: .existingTicket, source: source))
    }

    func beginMergeRequestReview(iid: String, title: String?, url: URL) {
        let source = SessionLaunchSource.gitLabMergeRequest(iid: iid, title: title, url: url)
        startContextualLaunch(draft(purpose: .review, source: source))
    }

    // MARK: - Launch

    /// Resolves and launches a draft. Returns the new session ID, or nil when
    /// a one-time workspace choice is now pending at MainView.
    @discardableResult
    func launch(draft: SessionDraft) throws -> UUID? {
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
            starterPrompt: draft.starterPrompt
        )
        return nil
    }

    /// Confirms the one-time choice; the association is remembered so later
    /// launches of the same source are one click.
    @discardableResult
    func confirmWorkspaceChoice(workspaceID: UUID) throws -> UUID? {
        guard let choice = pendingChoice else { return nil }
        guard SessionWorkspaceStore.meetsRequirement(
            for: workspaceStore.workspace(withID: workspaceID),
            purpose: choice.purpose
        ) else {
            throw LaunchError.workspaceUnavailable
        }
        pendingChoice = nil
        let draft = SessionDraft(
            purpose: choice.purpose,
            source: choice.source,
            starterPrompt: choice.starterPrompt,
            name: choice.name,
            workspaceID: workspaceID
        )
        return try performLaunch(draft: draft, workspaceID: workspaceID, rememberingAssociation: true)
    }

    func cancelWorkspaceChoice() {
        pendingChoice = nil
    }

    func clearFailure() {
        lastFailureMessage = nil
    }

    private func startContextualLaunch(_ draft: SessionDraft) {
        do {
            _ = try launch(draft: draft)
        } catch {
            lastFailureMessage = error.localizedDescription
        }
    }

    private func performLaunch(
        draft: SessionDraft,
        workspaceID: UUID,
        rememberingAssociation: Bool
    ) throws -> UUID {
        guard let workspace = workspaceStore.workspace(withID: workspaceID),
              SessionWorkspaceStore.meetsRequirement(for: workspace, purpose: draft.purpose) else {
            throw LaunchError.workspaceUnavailable
        }

        if rememberingAssociation, let identity = draft.source?.routingIdentity {
            workspaceStore.rememberAssociation(routingIdentity: identity, workspaceID: workspaceID)
        }
        workspaceStore.noteUse(workspaceID: workspaceID, purpose: draft.purpose)

        let request = SessionCreationRequest(
            purpose: draft.purpose,
            name: draft.name,
            workingDirectory: workspace.directoryURL,
            source: draft.source,
            starterPrompt: draft.starterPrompt ?? StarterPromptBuilder.prompt(for: draft.purpose, source: draft.source)
        )

        do {
            let sessionID = try store.createSession(request: request)
            ConsoleNavigation.showSessions()
            return sessionID
        } catch {
            lastFailureMessage = error.localizedDescription
            throw error
        }
    }

    private func resolveWorkspace(purpose: SessionPurpose, source: SessionLaunchSource?) -> SessionWorkspace? {
        // 2. Remembered association for this ticket/MR project.
        if let identity = source?.routingIdentity,
           let rememberedID = workspaceStore.associatedWorkspaceID(forRoutingIdentity: identity),
           let remembered = workspaceStore.workspace(withID: rememberedID),
           SessionWorkspaceStore.meetsRequirement(for: remembered, purpose: purpose) {
            return remembered
        }

        // 3. Unique GitLab remote match for review sources.
        if case let .gitLabMergeRequest(_, _, url) = source,
           let identity = GitLabSourceContext.projectIdentity(fromMergeRequestURL: url) {
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

    // MARK: - Starter prompt delivery (memory-only)

    private var automaticallyStartsContextualWork: Bool {
        workspaceStore.automaticallyStartsContextualWork
    }

    private func handleLifecycleEvent(sessionID: UUID, event: SessionLifecycleEvent) {
        switch event {
        case .sessionStarted:
            guard automaticallyStartsContextualWork,
                  let prompt = store.pendingStarterPrompt(for: sessionID) else { return }
            // Clearing before submitting is the exactly-once guarantee.
            store.setPendingStarterPrompt(nil, for: sessionID)
            _ = store.submitStarterPrompt(prompt, to: sessionID)

        case .turnFailed, .processTerminated, .sessionEnded:
            store.setPendingStarterPrompt(nil, for: sessionID)

        case .promptSubmitted, .permissionRequested, .questionAsked, .turnCompleted,
             .cwdChanged, .attentionReported, .artifactLinked, .completionReported, .userInputObserved:
            break
        }
    }

    /// Manual Send Starter Prompt (banner). Bypasses the idle-only gate
    /// because bridge-unavailable sessions never report activity changes.
    @discardableResult
    func manuallySendStarterPrompt(to sessionID: UUID) -> SubmissionResult {
        guard let prompt = store.pendingStarterPrompt(for: sessionID) else {
            return .rejected(.emptyPrompt)
        }
        store.setPendingStarterPrompt(nil, for: sessionID)
        return store.submitStarterPrompt(prompt, to: sessionID)
    }
}
