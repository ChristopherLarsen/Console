import Foundation
import WebKit

/// A prepared launch: automatic local display name. Source metadata stays
/// local.
struct SessionDraft: Equatable {
    let purpose: SessionPurpose
    let source: SessionLaunchSource?
    var name: String
    /// Claude Code agent this launch runs under; nil keeps the purpose default.
    var agent: String? = nil
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
        case resumeFolderMissing
        case resumeTranscriptMissing

        var errorDescription: String? {
            switch self {
            case .sessionFolderMissing:
                return "Choose a Session Folder in Settings → Claude."
            case .sessionFolderUnavailable:
                return "The Session Folder is no longer available. Choose another in Settings → Claude."
            case .sessionFolderNotAGitRepository:
                return "Review sessions need a Git repository. Choose a Session Folder that contains a Git checkout in Settings → Claude."
            case .resumeFolderMissing:
                return "The session's working folder no longer exists, so it cannot be resumed."
            case .resumeTranscriptMissing:
                return "That transcript is no longer available, so the session cannot be resumed."
            }
        }
    }

    /// Contextual-launch failure. MainView presents it.
    private(set) var lastFailure: SessionLaunchFailure?
    var pendingAuthoredMR: AuthoredMRAttention?
    private(set) var isOpeningAuthoredMR = false
    @ObservationIgnored private var resumingConversations = Set<UUID>()

    var lastFailureMessage: String? { lastFailure?.message }

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let workspaceStore: SessionWorkspaceStore
    /// Root of Claude's local transcript history, checked before a resume.
    @ObservationIgnored private let historyRoot: URL

    init(
        store: SessionStore,
        workspaceStore: SessionWorkspaceStore,
        historyRoot: URL = SessionHistoryReader.claudeProjectsRoot
    ) {
        self.store = store
        self.workspaceStore = workspaceStore
        self.historyRoot = historyRoot
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
    /// new-ticket card passes the new-ticket rule (`NMA-1234` → `NMA-1234`);
    /// Jira-panel launches keep the automatic key name.
    func beginJiraTicketLaunch(key: String, title: String?, url: URL?, displayName: String? = nil, agent: String? = nil) async {
        let source = SessionLaunchSource.jira(key: key, title: title, url: url)
        var prepared = draft(purpose: .existingTicket, source: source)
        if let displayName { prepared.name = displayName }
        prepared.agent = agent
        await startContextualLaunch(prepared)
    }

    /// `displayName` overrides the automatic MR-based session name. Home's
    /// review card passes the Jira-keyed review name ("NMA-1234 Review");
    /// the MR page keeps the automatic name. A display name also queues
    /// `/rename <name>` and `/color purple` so the running Claude Code
    /// session matches once its bridge reports it live.
    func beginMergeRequestReview(iid: String, title: String?, url: URL, displayName: String? = nil) async {
        lastFailure = nil
        switch HomeStorySessionMatcher.reviewResolution(
            for: url, in: store.sessions, associations: store.associations
        ) {
        case .live(let id):
            store.select(sessionID: id)
            ConsoleNavigation.showSessions()
            store.focusSelectedTerminal()
            return
        case .resumable(let record):
            do { _ = try await launchResume(record: record) }
            catch { lastFailure = SessionLaunchFailure(error: error) }
            return
        case .none:
            break
        }
        let source = SessionLaunchSource.mergeRequest(iid: iid, title: title, url: url)
        var prepared = draft(purpose: .review, source: source)
        if let displayName { prepared.name = displayName }
        let sessionID = await startContextualLaunch(prepared)
        guard let displayName, let sessionID,
              let session = store.session(withID: sessionID) else { return }
        store.queueSlashCommand("/rename \(session.name)", for: sessionID)
        store.queueSlashCommand("/color purple", for: sessionID)
    }

    /// The previous review session a Review card can continue, for its button
    /// label and action.
    func reviewSessionResolution(for url: URL) -> HomeStorySessionMatcher.ReviewResolution {
        HomeStorySessionMatcher.reviewResolution(
            for: url, in: store.sessions, associations: store.associations
        )
    }

    /// Self Review: a fresh review session for one of the user's own open
    /// merge requests. Always runs under the review agent and always creates a
    /// new session, queuing `/rename MR-<iid> Self Review` plus `/color
    /// purple` so the running Claude Code session matches the local name.
    func beginSelfReview(iid: String, title: String?, url: URL) async {
        lastFailure = nil
        let source = SessionLaunchSource.mergeRequest(iid: iid, title: title, url: url)
        var prepared = draft(purpose: .review, source: source)
        prepared.name = "MR-\(iid) Self Review"
        prepared.agent = SessionStore.reviewAgentName
        let sessionID = await startContextualLaunch(prepared)
        guard let sessionID, let session = store.session(withID: sessionID) else { return }
        store.queueSlashCommand("/rename \(session.name)", for: sessionID)
        store.queueSlashCommand("/color purple", for: sessionID)
    }

    /// Agent Review: a fresh review session with no merge request attached.
    /// Runs under the review agent, names itself `agent-review`, and queues
    /// `/rename agent-review` plus `/color purple`.
    func beginAgentReview() async {
        lastFailure = nil
        var prepared = draft(purpose: .review, source: nil)
        prepared.name = SessionStore.reviewAgentName
        prepared.agent = SessionStore.reviewAgentName
        let sessionID = await startContextualLaunch(prepared)
        guard let sessionID, let session = store.session(withID: sessionID) else { return }
        store.queueSlashCommand("/rename \(session.name)", for: sessionID)
        store.queueSlashCommand("/color purple", for: sessionID)
    }

    // MARK: - Launch

    // MARK: - Launch

    /// Validates the Session Folder and launches. Returns the new session ID.
    ///
    /// Does not record `lastFailure` — the intent picker surfaces thrown
    /// errors itself. Contextual toolbar/card launches go through
    /// `startContextualLaunch`.
    @discardableResult
    func launch(draft: SessionDraft) async throws -> UUID {
        lastFailure = nil

        let folder = try validatedSessionFolder(purpose: draft.purpose)
        return try await performLaunch(draft: draft, folder: folder)
    }

    /// Resumes a previous Claude conversation by its session ID. The
    /// transcript and recorded working directory are validated first.
    @discardableResult
    func launchResume(record: SessionRestorationRecord) async throws -> UUID {
        lastFailure = nil
        if let active = store.sessions.first(where: { $0.claudeSessionID == record.id && $0.activity != .exited }) {
            store.select(sessionID: active.id)
            ConsoleNavigation.showSessions()
            store.focusSelectedTerminal()
            return active.id
        }
        guard resumingConversations.insert(record.id).inserted else { throw POSIXError(.EBUSY) }
        defer { resumingConversations.remove(record.id) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: record.workingDirectory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LaunchError.resumeFolderMissing
        }
        let transcriptURL = historyRoot
        guard directoryContainsTranscript(named: record.claudeSessionID.uuidString, under: transcriptURL) else {
            throw LaunchError.resumeTranscriptMissing
        }

        try await store.checkConversationAvailable(record)
        try Task.checkCancellation()
        if let active = store.sessions.first(where: { $0.claudeSessionID == record.id && $0.activity != .exited }) {
            store.select(sessionID: active.id)
            ConsoleNavigation.showSessions()
            store.focusSelectedTerminal()
            return active.id
        }
        var prepared = draft(purpose: record.purpose, source: nil)
        prepared.name = record.name
        return try await performLaunch(
            draft: prepared,
            workingDirectory: record.workingDirectory,
            action: .resume(record: record)
        )
    }

    func openAuthoredMR(_ item: AuthoredMRAttention) async {
        guard !isOpeningAuthoredMR else { return }
        isOpeningAuthoredMR = true
        defer { isOpeningAuthoredMR = false }
        lastFailure = nil
        guard let conversation = store.associations.author(for: item.url) else {
            pendingAuthoredMR = item
            return
        }
        do {
            let id = try await launchResume(record: conversation.record)
            try store.linkAuthoredMR(item, sessionID: id)
            store.focusSelectedTerminal()
        } catch {
            lastFailure = SessionLaunchFailure(error: error)
            pendingAuthoredMR = item
        }
    }

    /// Explicit choice: either an existing conversation or a fresh authoring session.
    func linkAuthoredMR(_ item: AuthoredMRAttention, record: SessionRestorationRecord?) async throws {
        guard !isOpeningAuthoredMR else { throw POSIXError(.EBUSY) }
        isOpeningAuthoredMR = true
        defer { isOpeningAuthoredMR = false }
        let id: UUID
        if let record {
            id = try await launchResume(record: record)
        } else {
            id = try await launch(draft: draft(purpose: .general,
                source: .mergeRequest(iid: String(item.iid), title: item.title, url: item.url)))
        }
        try store.linkAuthoredMR(item, sessionID: id)
        pendingAuthoredMR = nil
        store.focusSelectedTerminal()
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

    /// Validates the Session Folder and launches. Returns the created
    /// session ID, or nil when the launch failed (the failure is recorded).
    @discardableResult
    private func startContextualLaunch(_ draft: SessionDraft) async -> UUID? {
        do {
            return try await launch(draft: draft)
        } catch {
            lastFailure = SessionLaunchFailure(error: error)
            return nil
        }
    }

    private func performLaunch(
        draft: SessionDraft,
        folder: SessionWorkspace
    ) async throws -> UUID {
        try await performLaunch(
            draft: draft,
            workingDirectory: folder.directoryURL,
            action: .create(request: SessionCreationRequest(
                purpose: draft.purpose,
                name: draft.name,
                workingDirectory: folder.directoryURL,
                source: draft.source,
                agent: draft.agent
            ))
        )
    }

    /// Creates or resumes the session in the requested directory. Sessions
    /// always share the same project folder, so nothing gates the launch.
    private func performLaunch(
        draft: SessionDraft,
        workingDirectory: URL,
        action: PendingLaunchAction
    ) async throws -> UUID {
        let sessionID: UUID
        switch action {
        case .create(let request):
            sessionID = try store.createSession(request: request)
        case .resume(let record):
            sessionID = try store.resumeSession(from: record)
        }

        lastFailure = nil
        ConsoleNavigation.showSessions()
        return sessionID
    }

    /// Cheap transcript-existence check for the resume path: any project
    /// directory under Claude's history root may hold the transcript.
    private func directoryContainsTranscript(named sessionID: String, under root: URL) -> Bool {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let fileName = "\(sessionID).jsonl"
        for projectDir in projectDirs {
            if fileManager.fileExists(atPath: projectDir.appendingPathComponent(fileName).path) {
                return true
            }
        }
        return false
    }

    /// Opens Settings so the user can fix the Claude executable or the
    /// Session Folder.
    func openSessionsSettings() {
        lastFailure = nil
        ConsoleNavigation.showSettings()
    }

    func clearFailure() {
        lastFailure = nil
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
