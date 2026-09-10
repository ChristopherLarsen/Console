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
@MainActor
final class HomeSourcesCoordinator {
    private let jiraController: JiraPanelController
    private let reviewsController: CodeHostListPanelController
    private let jiraURLProvider: () -> String?

    init(
        jiraController: JiraPanelController,
        reviewsController: CodeHostListPanelController,
        jiraURLProvider: @escaping () -> String?
    ) {
        self.jiraController = jiraController
        self.reviewsController = reviewsController
        self.jiraURLProvider = jiraURLProvider
    }

    /// Idempotent activation when Home appears: configure Jira from the
    /// current Settings URL (a no-op when unchanged and already extracted)
    /// and resume the reviews list without forcing a reload of healthy data.
    func activate() {
        jiraController.configure(url: configuredJiraURL)
        reviewsController.startIfNeeded()
    }

    /// The configured Jira URL changed in Settings; restart extraction only
    /// when the effective URL actually differs.
    func jiraURLChanged() {
        jiraController.configure(url: configuredJiraURL)
    }

    func refreshJira() {
        jiraController.refresh()
    }

    func refreshReviews() {
        reviewsController.refresh()
    }

    func refreshAll() {
        refreshJira()
        refreshReviews()
    }

    private var configuredJiraURL: URL? {
        jiraURLProvider().flatMap(JiraView.normalizedURL(from:))
    }
}
