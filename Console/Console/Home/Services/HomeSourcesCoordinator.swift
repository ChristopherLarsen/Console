import Foundation

/// Home's source activation: keeps the Jira panel controller pointed at the
/// configured list URL and keeps the reviews-requested extraction alive while
/// Home is visible.
///
/// Since the Home panels were removed, nothing else configures the shared
/// `JiraPanelController`; Home owns that job on appear and whenever the
/// Settings URL changes. The MR list controller is process-scoped and already
/// reads its configured URL through its own provider — Home only asks it to
/// start or resume.
///
/// Entering Home also performs a staleness pass: Next and In Progress share
/// the Jira source and Review reads the reviews-requested list, and each is
/// refreshed only when its last successful refresh is missing or older than
/// the 15-minute window. Fresh retained data is never re-extracted, work in
/// flight is never doubled, and a sign-in flow always wins over background
/// refresh. Review refreshes are dispatched through `refreshReviewsHandler`
/// (production: `MRReviewScanScheduler.scanOnAppearance`) so the retained GitLab
/// page's user navigation keeps winning over background work.
@MainActor
final class HomeSourcesCoordinator {
    /// Entry-time staleness window for the board's columns.
    static let autoRefreshInterval: TimeInterval = 15 * 60

    private let jiraController: JiraPanelController
    private let reviewsController: CodeHostListPanelController
    private let jiraURLProvider: () -> String?
    private let now: () -> Date

    /// Refresh entry for the Review column. HomeView wires
    /// `MRReviewScanScheduler.scanOnAppearance` so the scheduler's in-flight guard and
    /// the retained-page-away protections apply. Unwired (previews), the
    /// review staleness pass is a no-op.
    var refreshReviewsHandler: (@MainActor () -> Void)?

    init(
        jiraController: JiraPanelController,
        reviewsController: CodeHostListPanelController,
        jiraURLProvider: @escaping () -> String?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.jiraController = jiraController
        self.reviewsController = reviewsController
        self.jiraURLProvider = jiraURLProvider
        self.now = now
    }

    /// Idempotent activation when Home appears: configure Jira from the
    /// current Settings URL (a no-op when unchanged and already extracted),
    /// resume the reviews list without forcing a reload of healthy data, and
    /// refresh whichever source's last successful refresh is missing or
    /// older than the staleness window.
    func activate() {
        jiraController.configure(url: configuredJiraURL)
        reviewsController.startIfNeeded()
        refreshStaleSources()
    }

    /// The configured Jira URL changed in Settings; restart extraction only
    /// when the effective URL actually differs.
    func jiraURLChanged() {
        jiraController.configure(url: configuredJiraURL)
    }

    func refreshJira() {
        jiraController.refresh()
    }

    /// Entry-time staleness pass. Both columns of the Jira source share one
    /// decision; Review dispatches through `refreshReviewsHandler`.
    func refreshStaleSources() {
        let jiraState = jiraController.state
        if !jiraController.isRefreshing, isRefreshEligible(jiraState),
           Self.needsAutoRefresh(lastRefreshedAt: jiraState.refreshedAt, now: now()) {
            jiraController.refresh()
        }

        let reviewState = reviewsController.state
        if !reviewsController.isRefreshing, !reviewsController.wantsAuthenticationObservation,
           isRefreshEligible(reviewState),
           Self.needsAutoRefresh(lastRefreshedAt: reviewState.refreshedAt, now: now()) {
            refreshReviewsHandler?()
        }
    }

    /// True when a source should be refreshed on entry: never while
    /// extraction is in flight, sign-in is required, or nothing is
    /// configured; otherwise per the staleness window.
    private func isRefreshEligible(_ state: JiraPanelState) -> Bool {
        switch state {
        case .unconfigured, .loadingPage, .extracting, .authenticationRequired:
            return false
        case .loaded, .empty, .stale, .unsupportedPage, .extractionFailed:
            return true
        }
    }

    private func isRefreshEligible(_ state: MergeRequestListPanelState) -> Bool {
        switch state {
        case .unconfigured, .loadingPage, .extracting, .authenticationRequired:
            return false
        case .loaded, .empty, .stale, .unsupportedPage, .extractionFailed:
            return true
        }
    }

    /// True when a source must be refreshed: no successful refresh on
    /// record, or the newest one is at least `interval` old.
    nonisolated static func needsAutoRefresh(
        lastRefreshedAt: Date?,
        now: Date,
        interval: TimeInterval = HomeSourcesCoordinator.autoRefreshInterval
    ) -> Bool {
        guard let lastRefreshedAt else { return true }
        return now.timeIntervalSince(lastRefreshedAt) >= interval
    }

    private var configuredJiraURL: URL? {
        jiraURLProvider().flatMap(JiraView.normalizedURL(from:))
    }
}
