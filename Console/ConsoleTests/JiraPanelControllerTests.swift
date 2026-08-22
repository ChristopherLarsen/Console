import XCTest
@testable import Console

@MainActor
final class JiraPanelControllerTests: XCTestCase {
    private final class FakeJiraPageService: JiraPageServicing {
        var lastLoadedURLString: String?
        var pageURL: URL?

        private(set) var loadedURLs: [URL] = []
        private(set) var reloadCount = 0
        private(set) var navigatedURLs: [URL] = []

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
            navigatedURLs.append(url)
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

    private let listURL1 = URL(string: "https://jira.example.com/issues/?jql=assignee=currentUser()")!
    private let listURL2 = URL(string: "https://jira.example.com/issues/?jql=other")!

    private var service = FakeJiraPageService()
    private var controller: JiraPanelController!

    override func setUp() {
        super.setUp()
        service = FakeJiraPageService()
        controller = JiraPanelController(service: service)
    }

    private func waitFor(
        _ condition: @autoclosure () -> Bool,
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

    private var sampleTickets: [JiraTicketSummary] {
        [
            JiraTicketSummary(key: "DEMO-2", summary: "second", status: "In Progress", priority: "High", updatedText: nil, issueURL: URL(string: "https://jira.example.com/browse/DEMO-2")!, sourceOrder: 0),
            JiraTicketSummary(key: "DEMO-1", summary: "first", status: "Backlog", priority: nil, updatedText: nil, issueURL: URL(string: "https://jira.example.com/browse/DEMO-1")!, sourceOrder: 1),
        ]
    }

    func testUnconfiguredWhenNoURLOriginallyConfigured() async {
        controller.configure(url: nil)
        XCTAssertEqual(controller.state, .unconfigured)
        XCTAssertFalse(controller.showsBrowser)
    }

    func testSuccessfulConfigureLoadsAndShowsCards() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)

        controller.configure(url: listURL1)

        await waitFor(controller.state.hasCards)
        XCTAssertEqual(service.loadedURLs.first, listURL1)
        XCTAssertEqual(controller.state.tickets.map(\.key), ["DEMO-2", "DEMO-1"])
        XCTAssertFalse(controller.showsBrowser)
        if case .loaded(_, let refreshedAt) = controller.state {
            XCTAssertLessThan(refreshedAt.timeIntervalSinceNow, 5)
        } else {
            XCTFail("expected loaded state")
        }
    }

    func testAuthenticationRevealsBrowser() async {
        service.readinessResult = .authenticationDetected

        controller.configure(url: listURL1)

        await waitFor(controller.state == .authenticationRequired)
        XCTAssertTrue(controller.showsBrowser)
    }

    func testPostAuthenticationWatchExtractsWhenRowsAppear() async {
        service.readinessResult = .authenticationDetected
        controller.configure(url: listURL1)
        await waitFor(controller.state == .authenticationRequired)

        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)

        await waitFor(controller.state.hasCards, timeout: 6)
        XCTAssertFalse(controller.showsBrowser)
        XCTAssertEqual(controller.state.tickets.map(\.key), ["DEMO-2", "DEMO-1"])
    }

    func testPostAuthenticationWatchStaysInAuthStateWithoutRows() async {
        service.readinessResult = .authenticationDetected
        controller.configure(url: listURL1)
        await waitFor(controller.state == .authenticationRequired)

        try? await Task.sleep(nanoseconds: 2_500_000_000)

        guard case .authenticationRequired = controller.state else {
            return XCTFail("expected authentication state to persist")
        }
    }

    func testUnsupportedPageWithoutPriorCardsShowsBrowser() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .unsupportedPage

        controller.configure(url: listURL1)

        await waitFor(controller.state == .unsupportedPage)
        XCTAssertTrue(controller.showsBrowser)
    }

    func testExtractionFailureWithoutPriorCardsShowsBrowserNeverFalseEmpty() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .failed

        controller.configure(url: listURL1)

        await waitFor(controller.state == .extractionFailed)
        XCTAssertTrue(controller.showsBrowser)
    }

    func testEmptyListIsPositiveStateNotBrowserForced() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .empty

        controller.configure(url: listURL1)

        await waitFor({
            if case .empty = controller.state { return true }
            return false
        }())
        XCTAssertFalse(controller.showsBrowser)
    }

    func testRefreshFailureRetainsPreviousCardsAsStale() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        service.extractionResult = .failed
        controller.refresh()

        await waitFor(isStaleWithKeys(["DEMO-2", "DEMO-1"]))
        if case let .stale(tickets, _, reason) = controller.state {
            XCTAssertEqual(tickets.map(\.key), ["DEMO-2", "DEMO-1"])
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("expected stale state")
        }
    }

    func testRefreshFailureOnUnsupportedKeepsPreviousCardsStale() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        service.extractionResult = .unsupportedPage
        controller.refresh()

        await waitFor(isStaleWithKeys(["DEMO-2", "DEMO-1"]))
    }

    func testSuccessfulRefreshReplacesCardsAtomically() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        let replacement = [
            JiraTicketSummary(key: "DEMO-9", summary: "newest", status: "Next Up", priority: nil, updatedText: nil, issueURL: URL(string: "https://jira.example.com/browse/DEMO-9")!, sourceOrder: 0),
        ]
        service.extractionResult = .tickets(replacement)
        controller.refresh()

        await waitFor(controller.state.tickets.map(\.key) == ["DEMO-9"])
        XCTAssertEqual(controller.state.tickets.count, 1)
        if case .loaded = controller.state {} else {
            XCTFail("expected loaded state after successful refresh")
        }
    }

    func testReconfigureMidFlightDiscardsStaleResults() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        let otherTickets = [
            JiraTicketSummary(key: "OTHER-1", summary: "other list", status: nil, priority: nil, updatedText: nil, issueURL: URL(string: "https://jira.example.com/browse/OTHER-1")!, sourceOrder: 0),
        ]
        service.extractionResult = .failed
        service.holdNextExtraction()
        controller.refresh()
        await waitFor(service.extractionCount >= 2)

        controller.configure(url: listURL2)
        service.extractionResult = .tickets(otherTickets)
        service.releaseHeldExtraction()

        await waitFor(controller.state.tickets.map(\.key) == ["OTHER-1"])
        XCTAssertEqual(service.loadedURLs.last, listURL2)
        if case .stale = controller.state {
            XCTFail("stale results from previous page must never win")
        }
    }

    func testOpenNavigatesSharedPageToIssueURLAndRevealsBrowser() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        let ticket = sampleTickets[0]
        controller.open(ticket)

        XCTAssertTrue(controller.showsBrowser)
        XCTAssertEqual(service.navigatedURLs.last, ticket.issueURL)
    }

    func testShowJIRARevealsSamePageWithoutReloading() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)
        let loadsBeforeToggle = service.loadedURLs.count

        controller.showJIRA()

        XCTAssertTrue(controller.showsBrowser)
        XCTAssertEqual(service.loadedURLs.count, loadsBeforeToggle)
    }

    func testShowCardsRestoresOverlayAfterSuccessfulExtraction() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        controller.showJIRA()
        XCTAssertTrue(controller.showsBrowser)
        controller.showCards()

        XCTAssertFalse(controller.showsBrowser)
    }

    func testReconfigureWithSameURLDoesNotResetLoadedCards() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        controller.configure(url: listURL1)

        XCTAssertEqual(controller.state.tickets.count, 2)
        if case .loadingPage = controller.state {
            XCTFail("re-appearing Home must not discard cards")
        }
    }

    func testSameURLConfigureDuringRefreshDoesNotCancelRefresh() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        let replacement = [
            JiraTicketSummary(key: "DEMO-9", summary: "newest", status: "Next Up", priority: nil, updatedText: nil, issueURL: URL(string: "https://jira.example.com/browse/DEMO-9")!, sourceOrder: 0),
        ]
        service.extractionResult = .tickets(replacement)
        service.holdNextExtraction()
        controller.refresh()
        await waitFor(service.extractionCount >= 2)

        controller.configure(url: listURL1)
        service.releaseHeldExtraction()

        await waitFor(controller.state.tickets.map(\.key) == ["DEMO-9"])
        if case .loaded = controller.state {} else {
            XCTFail("same-URL configure must not cancel an in-flight refresh")
        }
        XCTAssertFalse(controller.isRefreshing)
    }

    func testPostAuthenticationEmptyShowsCardsNotBrowser() async {
        service.readinessResult = .authenticationDetected
        controller.configure(url: listURL1)
        await waitFor(controller.state == .authenticationRequired)
        XCTAssertTrue(controller.showsBrowser)

        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .empty

        await waitFor({
            if case .empty = controller.state { return true }
            return false
        }(), timeout: 6)
        XCTAssertFalse(controller.showsBrowser)
    }

    func testChangingConfiguredURLReloadsPage() async {
        service.readinessResult = .pending(hasRows: true, hasContainer: true)
        service.extractionResult = .tickets(sampleTickets)
        controller.configure(url: listURL1)
        await waitFor(controller.state.hasCards)

        service.extractionResult = .empty
        controller.configure(url: listURL2)

        await waitFor({
            if case .empty = controller.state { return true }
            return false
        }())
        XCTAssertTrue(service.loadedURLs.contains(listURL2))
        XCTAssertEqual(service.lastLoadedURLString, listURL2.absoluteString)
    }

    private func isStaleWithKeys(_ keys: [String]) -> Bool {
        if case let .stale(tickets, _, _) = controller.state {
            return tickets.map(\.key) == keys
        }
        return false
    }
}
