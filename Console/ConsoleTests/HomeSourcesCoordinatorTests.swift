import XCTest
import WebKit
@testable import Console

/// Entry-time staleness behavior for the Home board: Next/In Progress share
/// the Jira source and Review reads the reviews-requested list, and each is
/// refreshed on Home entry only when its last successful refresh is missing
/// or older than the 15-minute window.
@MainActor
final class HomeSourcesCoordinatorTests: XCTestCase {

    // MARK: - Pure staleness decision

    func testNeedsAutoRefreshWithoutLastRefresh() {
        XCTAssertTrue(HomeSourcesCoordinator.needsAutoRefresh(lastRefreshedAt: nil, now: Date()))
    }

    func testNeedsAutoRefreshInsideWindowIsFalse() {
        let now = Date()
        XCTAssertFalse(
            HomeSourcesCoordinator.needsAutoRefresh(
                lastRefreshedAt: now.addingTimeInterval(-14 * 60),
                now: now
            )
        )
    }

    func testNeedsAutoRefreshAtWindowBoundaryIsTrue() {
        let now = Date()
        XCTAssertTrue(
            HomeSourcesCoordinator.needsAutoRefresh(
                lastRefreshedAt: now.addingTimeInterval(-HomeSourcesCoordinator.autoRefreshInterval),
                now: now
            )
        )
    }

    func testNeedsAutoRefreshBeyondWindowIsTrue() {
        let now = Date()
        XCTAssertTrue(
            HomeSourcesCoordinator.needsAutoRefresh(
                lastRefreshedAt: now.addingTimeInterval(-16 * 60),
                now: now
            )
        )
    }

    // MARK: - Fixtures

    private final class FakeJiraPageService: JiraPageServicing {
        var lastLoadedURLString: String?
        var pageURL: URL?

        private(set) var loadedURLs: [URL] = []
        private(set) var reloadCount = 0

        var readinessResult: JiraReadiness?
        var extractionResult: JiraListExtraction = .failed
        private var gateNextExtraction = false
        private var extractionGate: CheckedContinuation<Void, Never>?
        private(set) var extractionCount = 0

        func load(url: URL) {
            loadedURLs.append(url)
            lastLoadedURLString = url.absoluteString
            pageURL = url
        }

        func reload() {
            reloadCount += 1
        }

        func navigate(to url: URL) {
            pageURL = url
        }

        func readiness() async -> JiraReadiness? {
            readinessResult
        }

        func extractTickets() async -> JiraListExtraction {
            extractionCount += 1
            if gateNextExtraction {
                gateNextExtraction = false
                await withCheckedContinuation { continuation in
                    extractionGate = continuation
                }
            }
            return extractionResult
        }

        func holdNextExtraction() {
            gateNextExtraction = true
        }

        func releaseHeldExtraction() {
            extractionGate?.resume()
            extractionGate = nil
        }
    }

    private let listURL = URL(string: "https://jira.example.com/issues/?jql=assignee=currentUser()")!
    private let reviewsURLString = "https://gitlab.example.test/review-list"

    private var jiraService = FakeJiraPageService()

    private func makeSampleTickets() -> [JiraTicketSummary] {
        [
            JiraTicketSummary(
                key: "DEMO-1",
                summary: "first",
                status: "In Progress",
                priority: nil,
                updatedText: nil,
                issueURL: URL(string: "https://jira.example.com/browse/DEMO-1")!,
                sourceOrder: 0
            ),
        ]
    }

    /// Deterministic reviews controller: loader succeeds, executor returns
    /// the configured payload, no navigation noise.
    private func makeReviewsController(
        executorPayload: @escaping @MainActor () -> String,
        loader: (@MainActor (WebPage, URLRequest) async -> Bool)? = nil
    ) -> CodeHostListPanelController {
        CodeHostListPanelController(
            kind: .reviewsRequested,
            page: CodeHostWebSessionStore.makePage(dataStore: WKWebsiteDataStore.nonPersistent()),
            configuredURLStringProvider: { [reviewsURLString] in reviewsURLString },
            readinessAttempts: 1,
            readinessIntervalNanoseconds: 0,
            pageLoader: loader ?? { _, _ in true },
            extractionExecutor: { _ in executorPayload() },
            navigationEvents: { _ in AsyncStream { $0.finish() } }
        )
    }

    private func makeCoordinator(
        jiraController: JiraPanelController,
        reviewsController: CodeHostListPanelController,
        now: @escaping () -> Date = { Date() }
    ) -> HomeSourcesCoordinator {
        HomeSourcesCoordinator(
            jiraController: jiraController,
            reviewsController: reviewsController,
            jiraURLProvider: { [listURL] in listURL.absoluteString },
            now: now
        )
    }

    private func waitFor(
        _ condition: @autoclosure @MainActor () -> Bool,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition not met before timeout", file: file, line: line)
    }

    // MARK: - Jira source

    func testActivateWithFreshJiraDataDoesNotReextract() async {
        jiraService.readinessResult = .pending(hasRows: true, hasContainer: true)
        jiraService.extractionResult = .tickets(makeSampleTickets())
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: makeReviewsController { "" }
        )

        coordinator.activate()
        await waitFor(jiraService.extractionCount == 1)
        let extractionsAfterFirstEntry = jiraService.extractionCount
        let reloadsAfterFirstEntry = jiraService.reloadCount

        coordinator.activate()

        XCTAssertEqual(jiraService.extractionCount, extractionsAfterFirstEntry)
        XCTAssertEqual(jiraService.reloadCount, reloadsAfterFirstEntry)
    }

    func testActivateRefreshesJiraWhenOlderThanWindow() async {
        jiraService.readinessResult = .pending(hasRows: true, hasContainer: true)
        jiraService.extractionResult = .tickets(makeSampleTickets())
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: makeReviewsController { "" },
            now: { Date().addingTimeInterval(16 * 60) }
        )

        coordinator.activate()
        await waitFor(jiraService.extractionCount == 1)
        let reloadsBefore = jiraService.reloadCount

        coordinator.activate()

        await waitFor(jiraService.reloadCount == reloadsBefore + 1)
        // The refresh keeps the retained cards visible; it is a reload, not
        // a cold start.
        XCTAssertTrue(jiraService.extractionCount >= 2)
    }

    func testActivateDoesNotDoubleRefreshWhileJiraWorkInFlight() async {
        jiraService.readinessResult = .pending(hasRows: true, hasContainer: true)
        jiraService.extractionResult = .tickets(makeSampleTickets())
        jiraService.holdNextExtraction()
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: makeReviewsController { "" },
            now: { Date().addingTimeInterval(16 * 60) }
        )

        coordinator.activate()
        await waitFor(jiraService.extractionCount == 1)
        let reloadsBefore = jiraService.reloadCount

        // Still extracting: the staleness pass must not stack a reload.
        coordinator.activate()

        XCTAssertEqual(jiraService.reloadCount, reloadsBefore)
        jiraService.releaseHeldExtraction()
        await waitFor(jiraService.extractionCount == 2)
    }

    func testActivateSkipsStaleJiraRefreshWhileSignedOut() async {
        jiraService.readinessResult = .authenticationDetected
        let jiraController = JiraPanelController(service: jiraService)
        let coordinator = makeCoordinator(
            jiraController: jiraController,
            reviewsController: makeReviewsController { "" }
        )

        coordinator.activate()
        await waitFor(jiraController.state == .authenticationRequired)

        coordinator.activate()

        XCTAssertEqual(jiraService.reloadCount, 0, "sign-in recovery owns the page; no forced reload")
    }

    // MARK: - Review source

    func testActivateWithFreshReviewDataDoesNotRefresh() async {
        let reviewsController = makeReviewsController {
            "{\"outcome\":\"items\",\"items\":[{\"url\":\"https://gitlab.example.test/p/-/merge_requests/1\",\"title\":\"Fixture\"}]}"
        }
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: reviewsController
        )
        var refreshCount = 0
        coordinator.refreshReviewsHandler = { refreshCount += 1 }

        coordinator.activate()
        await waitFor(!reviewsController.isRefreshing)
        XCTAssertEqual(reviewsController.state.retainedItems.count, 1)

        coordinator.activate()

        XCTAssertEqual(refreshCount, 0)
    }

    func testActivateRefreshesReviewWhenOlderThanWindow() async {
        let reviewsController = makeReviewsController {
            "{\"outcome\":\"items\",\"items\":[{\"url\":\"https://gitlab.example.test/p/-/merge_requests/1\",\"title\":\"Fixture\"}]}"
        }
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: reviewsController,
            now: { Date().addingTimeInterval(16 * 60) }
        )
        var refreshCount = 0
        coordinator.refreshReviewsHandler = { refreshCount += 1 }

        coordinator.activate()
        await waitFor(!reviewsController.isRefreshing)
        XCTAssertEqual(refreshCount, 0, "first entry extracts via startIfNeeded, not the staleness pass")

        coordinator.activate()

        XCTAssertEqual(refreshCount, 1)
    }

    func testActivateSkipsStaleReviewRefreshWhileAwaitingSignIn() async {
        let reviewsController = makeReviewsController { "{\"outcome\":\"authenticationRequired\",\"items\":[]}" }
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: reviewsController,
            now: { Date().addingTimeInterval(16 * 60) }
        )
        var refreshCount = 0
        coordinator.refreshReviewsHandler = { refreshCount += 1 }

        coordinator.activate()
        await waitFor(reviewsController.state == .authenticationRequired)

        coordinator.activate()

        XCTAssertEqual(refreshCount, 0)
    }

    func testActivateSkipsStaleReviewRefreshWhileExtractionInFlight() async {
        let loaderGate = LoaderGate()
        let reviewsController = makeReviewsController(
            executorPayload: {
                "{\"outcome\":\"items\",\"items\":[{\"url\":\"https://gitlab.example.test/p/-/merge_requests/1\",\"title\":\"Fixture\"}]}"
            },
            loader: loaderGate.loader
        )
        let coordinator = makeCoordinator(
            jiraController: JiraPanelController(service: jiraService),
            reviewsController: reviewsController,
            now: { Date().addingTimeInterval(16 * 60) }
        )
        var refreshCount = 0
        coordinator.refreshReviewsHandler = { refreshCount += 1 }

        reviewsController.startIfNeeded()
        await waitFor(loaderGate.isGateHeld)

        coordinator.activate()

        XCTAssertEqual(refreshCount, 0, "an in-flight extraction must not be doubled")

        loaderGate.release()
        await waitFor(!reviewsController.isRefreshing)
    }

    /// Deterministic loader stall: `isGateHeld` flips only once the gated
    /// loader has actually stored its continuation, so `release()` can never
    /// race ahead of the extraction it is meant to unblock.
    private final class LoaderGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private(set) var isGateHeld = false

        var loader: @MainActor (WebPage, URLRequest) async -> Bool {
            { [weak self] _, _ in
                guard let self else { return false }
                return await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    self.isGateHeld = true
                }
            }
        }

        func release() {
            continuation?.resume(returning: true)
            continuation = nil
            isGateHeld = false
        }
    }
}
