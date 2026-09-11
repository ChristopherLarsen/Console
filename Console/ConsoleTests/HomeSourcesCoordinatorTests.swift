import XCTest
@testable import Console

@MainActor
final class HomeSourcesCoordinatorTests: XCTestCase {
    func testStalenessBoundary() {
        let now = Date()
        XCTAssertTrue(HomeSourcesCoordinator.needsAutoRefresh(lastRefreshedAt: nil, now: now))
        XCTAssertFalse(HomeSourcesCoordinator.needsAutoRefresh(lastRefreshedAt: now.addingTimeInterval(-899), now: now))
        XCTAssertTrue(HomeSourcesCoordinator.needsAutoRefresh(lastRefreshedAt: now.addingTimeInterval(-900), now: now))
    }

    private final class FakeJiraPageService: JiraPageServicing {
        var lastLoadedURLString: String?
        var pageURL: URL?
        var reloadCount = 0
        var extractionCount = 0
        var readinessResult: JiraReadiness? = .pending(hasRows: true, hasContainer: true)
        var hold = false
        var gate: CheckedContinuation<Void, Never>?
        func load(url: URL) { lastLoadedURLString = url.absoluteString; pageURL = url }
        func reload() { reloadCount += 1 }
        func navigate(to url: URL) { pageURL = url }
        func readiness() async -> JiraReadiness? { readinessResult }
        func extractTickets() async -> JiraListExtraction {
            extractionCount += 1
            if hold {
                hold = false
                await withCheckedContinuation { gate = $0 }
            }
            return .tickets([JiraTicketSummary(key: "DEMO-1", summary: "first", status: "In Progress",
                priority: nil, updatedText: nil, issueURL: URL(string: "https://jira.example.test/browse/DEMO-1")!, sourceOrder: 0)])
        }
    }

    private func coordinator(_ service: FakeJiraPageService, future: Bool = false) -> HomeSourcesCoordinator {
        HomeSourcesCoordinator(jiraController: JiraPanelController(service: service),
            jiraURLProvider: { "https://jira.example.test/issues/?jql=assignee=currentUser()" },
            now: { Date().addingTimeInterval(future ? 960 : 0) })
    }

    private func waitFor(_ condition: @autoclosure @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    func testFreshJiraDoesNotReextractAndReviewEntryUsesSchedulerSeam() async {
        let service = FakeJiraPageService()
        let coordinator = coordinator(service)
        var reviewChecks = 0
        coordinator.refreshReviewsHandler = { reviewChecks += 1 }
        coordinator.activate()
        await waitFor(service.extractionCount == 1)
        coordinator.activate()
        XCTAssertEqual(service.extractionCount, 1)
        XCTAssertEqual(service.reloadCount, 0)
        XCTAssertEqual(reviewChecks, 2, "Review scheduler owns staleness; no GitLab page is started")
    }

    func testOldJiraRefreshes() async {
        let service = FakeJiraPageService()
        let coordinator = coordinator(service, future: true)
        coordinator.activate()
        await waitFor(service.extractionCount == 1)
        coordinator.activate()
        await waitFor(service.reloadCount == 1)
    }

    func testJiraInFlightIsNotDoubled() async {
        let service = FakeJiraPageService()
        service.hold = true
        let coordinator = coordinator(service, future: true)
        coordinator.activate()
        await waitFor(service.gate != nil)
        coordinator.activate()
        XCTAssertEqual(service.reloadCount, 0)
        service.gate?.resume()
        service.gate = nil
    }

    func testSignedOutJiraDoesNotRefresh() async {
        let service = FakeJiraPageService()
        service.readinessResult = .authenticationDetected
        let controller = JiraPanelController(service: service)
        let coordinator = HomeSourcesCoordinator(jiraController: controller,
            jiraURLProvider: { "https://jira.example.test/issues/" })
        coordinator.activate()
        await waitFor(controller.state == .authenticationRequired)
        coordinator.activate()
        XCTAssertEqual(service.reloadCount, 0)
    }
}
