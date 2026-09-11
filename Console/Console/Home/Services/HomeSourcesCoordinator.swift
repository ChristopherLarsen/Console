import Foundation

/// Home activates Jira and asks the AI scheduler to check review staleness.
/// No GitLab page or DOM extraction is created by this coordinator.
@MainActor
final class HomeSourcesCoordinator {
    nonisolated static let autoRefreshInterval: TimeInterval = 15 * 60
    private let jiraController: JiraPanelController
    private let jiraURLProvider: () -> String?
    private let now: () -> Date
    var refreshReviewsHandler: (@MainActor () -> Void)?

    init(jiraController: JiraPanelController, jiraURLProvider: @escaping () -> String?,
         now: @escaping () -> Date = Date.init) {
        self.jiraController = jiraController
        self.jiraURLProvider = jiraURLProvider
        self.now = now
    }

    func activate() {
        jiraController.configure(url: configuredJiraURL)
        refreshStaleSources()
    }

    func jiraURLChanged() { jiraController.configure(url: configuredJiraURL) }
    func refreshJira() { jiraController.refresh() }

    func refreshStaleSources() {
        let state = jiraController.state
        if !jiraController.isRefreshing, isRefreshEligible(state),
           Self.needsAutoRefresh(lastRefreshedAt: state.refreshedAt, now: now()) {
            jiraController.refresh()
        }
        // The scheduler owns the review timestamp and in-flight guard.
        refreshReviewsHandler?()
    }

    private func isRefreshEligible(_ state: JiraPanelState) -> Bool {
        switch state {
        case .unconfigured, .loadingPage, .extracting, .authenticationRequired: return false
        case .loaded, .empty, .stale, .unsupportedPage, .extractionFailed: return true
        }
    }

    nonisolated static func needsAutoRefresh(lastRefreshedAt: Date?, now: Date,
        interval: TimeInterval = HomeSourcesCoordinator.autoRefreshInterval) -> Bool {
        guard let lastRefreshedAt else { return true }
        return now.timeIntervalSince(lastRefreshedAt) >= interval
    }

    private var configuredJiraURL: URL? { jiraURLProvider().flatMap(JiraView.normalizedURL(from:)) }
}
