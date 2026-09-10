import Foundation

/// State machine behind the Home work board: assembles the snapshot from the
/// live panel controllers (or an injected seam), decides click journeys with
/// verify-then-open semantics, and gates session launches.
///
/// Navigation is dispatched through `actionExecutor` when set (tests observe
/// without loading WebViews); otherwise the shared deep-link + navigation
/// path runs.
@MainActor
@Observable
final class HomeBoardModel {
    /// One navigation/handoff decision for a Home card.
    enum Action: Equatable, Sendable {
        case openJiraIssue(url: URL)
        case openMergeRequest(url: URL, list: CodeHostListKind)
        case openSettings
        case openJira
        case openGitLab
        case selectSession(UUID)
    }

    /// Quiet, data-free notice after a click's target vanished from current
    /// data. The board re-selects itself; the user stays on Home.
    static let vanishedNotice = "This item is no longer in this list."

    @ObservationIgnored var snapshotHandler: (@MainActor () -> HomeBoardSnapshot)?
    @ObservationIgnored var actionExecutor: (@MainActor (Action) -> Void)?
    @ObservationIgnored var selectSessionHandler: (@MainActor (UUID) -> Void)?
    @ObservationIgnored var startSessionHandler: (@MainActor (String, String?, URL?) async -> Void)?
    @ObservationIgnored var refreshJiraHandler: (@MainActor () -> Void)?

    private let jiraController: JiraPanelController
    private let reviewsController: CodeHostListPanelController

    /// Story keys with a launch resolution in flight; the card shows
    /// "Starting…" and duplicate activations are dropped.
    private(set) var launchingTicketKeys: Set<String> = []
    private(set) var notice: String?

    init(
        jiraController: JiraPanelController,
        reviewsController: CodeHostListPanelController
    ) {
        self.jiraController = jiraController
        self.reviewsController = reviewsController
    }

    // MARK: - Snapshot

    func snapshot() -> HomeBoardSnapshot {
        if let snapshotHandler { return snapshotHandler() }
        return Self.gatherSnapshot(jiraController: jiraController, reviewsController: reviewsController)
    }

    /// The renderable board. Reads observable controller state so SwiftUI
    /// tracks it inside the view body.
    var board: HomeBoard {
        HomeBoardBuilder.build(snapshot())
    }

    static func gatherSnapshot(
        jiraController: JiraPanelController,
        reviewsController: CodeHostListPanelController
    ) -> HomeBoardSnapshot {
        HomeBoardSnapshot(
            jiraTickets: jiraController.state.tickets,
            jiraStatus: HomeSourceStatus.from(jiraController.state),
            reviewItems: reviewsController.state.retainedItems,
            reviewStatus: HomeSourceStatus.from(reviewsController.state)
        )
    }

    // MARK: - Click journeys

    /// Next story: opens JIRA on the issue. Session creation is reserved for
    /// the In Progress column's explicit action.
    func openStory(_ ticket: JiraTicketSummary) {
        let snap = snapshot()
        if snap.jiraStatus.check == .current,
           !snap.jiraTickets.contains(ticket) {
            noteVanished()
            return
        }
        perform(.openJiraIssue(url: ticket.issueURL))
    }

    /// Review column rows: verify against current data, then deep-link to
    /// the specific merge request.
    func openReview(_ item: MergeRequestSummary) {
        let snap = snapshot()
        if snap.reviewStatus.check == .current,
           !snap.reviewItems.contains(where: { $0.id == item.id }) {
            noteVanished()
            return
        }
        perform(.openMergeRequest(url: item.mergeRequestURL, list: .reviewsRequested))
    }

    /// In Progress: open the story's live session, or start one. Stale Jira
    /// data may open an existing session but never launch; clicking then
    /// requests a refresh instead.
    func continueTicket(_ ticket: JiraTicketSummary, sessions: [ConsoleSession]) async {
        let snap = snapshot()
        if snap.jiraStatus.check == .current,
           !snap.jiraTickets.contains(ticket) {
            noteVanished()
            return
        }

        if let sessionID = HomeStorySessionMatcher.sessionID(for: ticket, in: sessions) {
            perform(.selectSession(sessionID))
            return
        }

        guard HomeBoardBuilder.canStartSession(jiraStatus: snap.jiraStatus) else {
            refreshJiraHandler?()
            return
        }

        guard !launchingTicketKeys.contains(ticket.key) else { return }
        launchingTicketKeys.insert(ticket.key)
        defer { launchingTicketKeys.remove(ticket.key) }
        let title = ticket.summary.isEmpty ? nil : ticket.summary
        await startSessionHandler?(ticket.key, title, ticket.issueURL)
    }

    /// Sets the view-side session-selection seam (needs the environment's
    /// `SessionStore`); falls back to a no-op when Home has no store.
    func selectSession(_ id: UUID) {
        perform(.selectSession(id))
    }

    func openSettings() { perform(.openSettings) }
    func openJiraSource() { perform(.openJira) }
    func openGitLabSource() { perform(.openGitLab) }

    /// Clears the transient notice once the user acts on anything.
    func clearNotice() {
        notice = nil
    }

    // MARK: - Dispatch

    private func noteVanished() {
        notice = Self.vanishedNotice
    }

    private func perform(_ action: Action) {
        notice = nil
        if let actionExecutor {
            actionExecutor(action)
            return
        }
        switch action {
        case .selectSession(let id):
            selectSessionHandler?(id)
        default:
            Self.executeNavigation(action)
        }
    }

    /// Shared navigation for non-session actions: set the one-shot deep link
    /// and switch the sidebar destination.
    static func executeNavigation(_ action: Action) {
        switch action {
        case .openJiraIssue(let url):
            JiraDeepLink.shared.set(url: url)
            ConsoleNavigation.show(.jira)
        case .openMergeRequest(let url, let list):
            MergeRequestDeepLink.shared.set(url: url, kind: list)
            ConsoleNavigation.show(.mergeRequests)
        case .openSettings:
            ConsoleNavigation.show(.settings)
        case .openJira:
            ConsoleNavigation.show(.jira)
        case .openGitLab:
            ConsoleNavigation.show(.mergeRequests)
        case .selectSession:
            break
        }
    }
}
