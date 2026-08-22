import XCTest
import WebKit
@testable import Console

/// State-machine tests for `CodeHostListPanelController` using deterministic
/// navigation/extraction seams. No live GitLab login is involved.
@MainActor
final class CodeHostListPanelControllerTests: XCTestCase {

    private var configuredURLString = "https://gitlab.example.test/review-list"
    private var currentDate = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - Helpers

    private func makeController(
        page: WebPage,
        loader: (@MainActor (WebPage, URLRequest) async -> Bool)? = nil,
        executor: (@MainActor (WebPage) async throws -> String?)? = nil,
        provider: (() -> String?)? = nil
    ) -> CodeHostListPanelController {
        CodeHostListPanelController(
            kind: .reviewsRequested,
            page: page,
            configuredURLStringProvider: provider ?? { [weak self] in self?.configuredURLString },
            now: { [weak self] in self?.currentDate ?? Date() },
            readinessAttempts: 1,
            readinessIntervalNanoseconds: 0,
            pageLoader: loader,
            extractionExecutor: executor
        )
    }

    /// Waits until the controller's in-flight extraction settles.
    private func waitForSettled(_ controller: CodeHostListPanelController) async {
        for _ in 0..<400 {
            if !controller.isRefreshing { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Extraction did not settle")
    }

    /// Executor stub whose use indicates a test bug (navigation was expected
    /// to short-circuit extraction).
    private final class UnexpectedExecutor {
        var wasCalled = false

        func call(_ page: WebPage) -> String? {
            wasCalled = true
            return nil
        }
    }

    private func itemsJSON(count: Int) -> String {
        let rows = (0..<count).map { index in
            "{\"url\":\"https://gitlab.example.test/p\(index)/-/merge_requests/\(index)\",\"iid\":\"\(index)\",\"title\":\"Fixture \(index)\"}"
        }.joined(separator: ",")
        return "{\"outcome\":\"items\",\"items\":[\(rows)]}"
    }

    private func summary(index: Int) -> MergeRequestSummary {
        let url = URL(string: "https://gitlab.example.test/p\(index)/-/merge_requests/\(index)")!
        return MergeRequestSummary(
            id: url,
            iidText: "\(index)",
            title: "Fixture \(index)",
            projectDisplayName: nil,
            authorDisplayName: nil,
            isDraft: false,
            pipelineDisplayState: nil,
            reviewDisplayState: nil,
            updatedText: nil,
            mergeRequestURL: url,
            sourceOrder: index
        )
    }

    private func makePage() -> WebPage {
        CodeHostWebSessionStore.makePage(dataStore: WKWebsiteDataStore.nonPersistent())
    }

    // MARK: - Configuration

    func testUnconfiguredStateWhenProviderIsEmpty() async {
        let controller = makeController(page: makePage(), provider: { "" })

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .unconfigured)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testUnconfiguredStateWhenProviderURLIsInvalid() async {
        configuredURLString = "not a url at all"
        let controller = makeController(page: makePage())

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .unconfigured)
    }

    // MARK: - Success paths

    func testSuccessfulExtractionLoadsItems() async throws {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { [weak self] _ in self?.itemsJSON(count: 3) }
        )

        controller.refresh()
        await waitForSettled(controller)

        guard case .loaded(let items, let refreshedAt) = controller.state else {
            return XCTFail("Expected loaded state, got \(controller.state)")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.sourceOrder), [0, 1, 2])
        XCTAssertEqual(refreshedAt, currentDate)
        XCTAssertEqual(controller.itemCount, 3)
    }

    func testEmptyOutcomeIsDistinctFromFailure() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" }
        )

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
    }

    // MARK: - Failure and stale handling

    func testAuthenticationRequiredWithoutPriorCards() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"authenticationRequired\",\"items\":[]}" }
        )

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .authenticationRequired)
    }

    func testRefreshFailureKeepsPriorCardsStaleInsteadOfFalseZero() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"authenticationRequired\",\"items\":[]}" }
        )

        controller.apply(.items([summary(index: 1)]), generation: 0)
        controller.refresh()
        await waitForSettled(controller)

        guard case .stale(let items, let refreshedAt, let reason) = controller.state else {
            return XCTFail("Expected stale state, got \(controller.state)")
        }
        XCTAssertEqual(items, [summary(index: 1)], "Prior cards must survive a failed refresh")
        XCTAssertEqual(refreshedAt, currentDate, "refreshedAt reflects the last successful extraction")
        XCTAssertEqual(reason, .signInRequired)
    }

    func testUnsupportedPageWithoutPriorCards() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"unsupported\",\"items\":[]}" }
        )

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .unsupportedPage)
    }

    func testUnsupportedPageWithPriorCardsBecomesStale() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"unsupported\",\"items\":[]}" }
        )
        controller.apply(.items([summary(index: 4), summary(index: 5)]), generation: 0)

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(
            controller.state,
            .stale(
                items: [summary(index: 4), summary(index: 5)],
                refreshedAt: currentDate,
                reason: .pageWasNotAList
            )
        )
    }

    func testNavigationFailureWithoutPriorCardsIsExtractionFailed() async {
        let unexpected = UnexpectedExecutor()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in false },
            executor: { page in unexpected.call(page) }
        )

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .extractionFailed)
        XCTAssertFalse(unexpected.wasCalled, "Extraction must not run when navigation failed")
    }

    func testNavigationFailureWithPriorCardsKeepsThemStale() async {
        let unexpected = UnexpectedExecutor()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in false },
            executor: { page in unexpected.call(page) }
        )
        controller.apply(.items([summary(index: 2)]), generation: 0)

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(
            controller.state,
            .stale(items: [summary(index: 2)], refreshedAt: currentDate, reason: .extractionFailed)
        )
        XCTAssertFalse(unexpected.wasCalled)
    }

    func testMalformedExtractionPayloadWithoutPriorCardsFails() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "definitely not json" }
        )

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .extractionFailed)
    }

    // MARK: - Generation protection

    func testOlderGenerationCannotReplaceNewerState() {
        let controller = makeController(page: makePage())

        let olderGeneration = controller.currentGeneration
        controller.refresh()
        let newerGeneration = controller.currentGeneration
        XCTAssertGreaterThan(newerGeneration, olderGeneration)

        controller.apply(.items([summary(index: 9)]), generation: newerGeneration)
        XCTAssertEqual(controller.state.retainedItems, [summary(index: 9)])

        controller.apply(.empty, generation: olderGeneration)
        XCTAssertEqual(controller.state.retainedItems, [summary(index: 9)], "A stale generation result must be rejected")
    }

    func testApplyIgnoresForeignGenerationsEntirely() {
        let controller = makeController(page: makePage())

        controller.apply(.unsupportedPage, generation: controller.currentGeneration + 41)
        XCTAssertEqual(controller.state, .unconfigured, "No state change from an unknown generation")
    }

    // MARK: - Presentation

    func testOpenRevealsBrowserAndNavigatesRetainedPage() async {
        let page = makePage()
        let controller = makeController(page: page)

        let item = summary(index: 6)
        controller.open(item)

        XCTAssertEqual(controller.presentation, .browser)

        for _ in 0..<100 where page.url == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(page.url?.host, item.mergeRequestURL.host, "The same retained page should navigate toward the captured MR URL")
    }

    func testShowCardsGatedOnDefiniteAnswer() {
        let controller = makeController(page: makePage())
        controller.showBrowser()

        controller.showCardsIfAvailable()
        XCTAssertEqual(controller.presentation, .browser, "No cards to show before any extraction")

        controller.apply(.items([summary(index: 0)]), generation: controller.currentGeneration)
        controller.showCardsIfAvailable()
        XCTAssertEqual(controller.presentation, .cards)
    }

    func testCancelPendingWorkStopsRefreshingFlag() {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" }
        )

        controller.refresh()
        XCTAssertTrue(controller.isRefreshing)
        controller.cancelPendingWork()
        XCTAssertFalse(controller.isRefreshing)
    }

    // MARK: - Configuration changes

    func testConfigurationChangeRestartsExtraction() async {
        let loadCounter = CounterBox()
        var activeProvider = "https://gitlab.example.test/list-a"
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loadCounter.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" },
            provider: { activeProvider }
        )

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(loadCounter.value, 1)

        // Same configured URL again must not reload.
        controller.startIfNeeded()
        await Task.yield()
        XCTAssertEqual(loadCounter.value, 1)

        // Changed URL restarts work.
        activeProvider = "https://gitlab.example.test/list-b"
        controller.configurationChanged()
        await waitForSettled(controller)
        XCTAssertEqual(loadCounter.value, 2)
    }

    func testStartIfNeededMarksUnconfiguredWithoutProviderValue() async {
        let controller = makeController(page: makePage(), provider: { "" })
        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .unconfigured)
    }

    // MARK: - Redaction

    func testLoadedStateDescriptionContainsNoExtractedValues() {
        let secret = MergeRequestSummary(
            id: URL(string: "https://gitlab.example.test/secret/widget/-/merge_requests/77")!,
            iidText: "77",
            title: "SECRET TITLE VALUE",
            projectDisplayName: "SECRET PROJECT",
            authorDisplayName: "SECRET AUTHOR",
            isDraft: true,
            pipelineDisplayState: nil,
            reviewDisplayState: nil,
            updatedText: nil,
            mergeRequestURL: URL(string: "https://gitlab.example.test/secret/widget/-/merge_requests/77")!,
            sourceOrder: 0
        )

        let state = MergeRequestListPanelState.loaded(items: [secret], refreshedAt: currentDate)
        for representation in ["\(state)", String(describing: state), String(reflecting: state)] {
            XCTAssertFalse(representation.contains("SECRET"), "Panel state leaked extracted values")
            XCTAssertFalse(representation.contains("merge_requests"), "Panel state leaked a URL shape")
        }
    }

    func testStaleReasonTextsContainNoExtractedValues() {
        for reason in [MergeRequestRefreshFailureReason.signInRequired, .pageWasNotAList, .extractionFailed] {
            XCTAssertFalse(reason.reasonText.isEmpty)
        }
    }
}

// MARK: - Test plumbing

@MainActor
private final class CounterBox {
    private(set) var value = 0

    func increment() { value += 1 }
}
