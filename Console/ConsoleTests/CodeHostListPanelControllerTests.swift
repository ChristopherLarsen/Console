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
        provider: (() -> String?)? = nil,
        navigationEvents: CodeHostListPanelController.NavigationEventSource? = nil,
        readinessAttempts: Int = 1
    ) -> CodeHostListPanelController {
        CodeHostListPanelController(
            kind: .reviewsRequested,
            page: page,
            configuredURLStringProvider: provider ?? { [weak self] in self?.configuredURLString },
            now: { [weak self] in self?.currentDate ?? Date() },
            readinessAttempts: readinessAttempts,
            readinessIntervalNanoseconds: 0,
            pageLoader: loader,
            extractionExecutor: executor,
            navigationEvents: navigationEvents ?? { _ in AsyncStream { $0.finish() } }
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

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not met", file: file, line: line)
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
        XCTAssertEqual(controller.presentation, .browser, "Sign-in must reveal the retained WebView")
        XCTAssertTrue(controller.wantsAuthenticationObservation)
        XCTAssertFalse(controller.canShowCards, "Show Cards must not cover the login page")
        XCTAssertTrue(controller.hiddenItems.isEmpty)
        XCTAssertEqual(controller.itemCount, 0)
    }

    func testAuthenticationWithPriorCardsHidesThemAndRevealsBrowser() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"authenticationRequired\",\"items\":[]}" }
        )

        controller.apply(.items([summary(index: 1)]), generation: 0)
        XCTAssertEqual(controller.presentation, .cards)

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(controller.presentation, .browser)
        XCTAssertEqual(controller.state.retainedItems, [], "Cards must not stay presented during sign-in")
        XCTAssertEqual(controller.hiddenItems, [summary(index: 1)], "Prior rows stay in memory only")
        XCTAssertEqual(controller.itemCount, 0)
        XCTAssertFalse(controller.canShowCards)
        XCTAssertTrue(controller.wantsAuthenticationObservation)
    }

    func testRefreshFailureKeepsPriorCardsStaleInsteadOfFalseZero() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "definitely not json" }
        )

        controller.apply(.items([summary(index: 1)]), generation: 0)
        controller.refresh()
        await waitForSettled(controller)

        guard case .stale(let items, let refreshedAt, let reason) = controller.state else {
            return XCTFail("Expected stale state, got \(controller.state)")
        }
        XCTAssertEqual(items, [summary(index: 1)], "Prior cards must survive a failed refresh")
        XCTAssertEqual(refreshedAt, currentDate, "refreshedAt reflects the last successful extraction")
        XCTAssertEqual(reason, .extractionFailed)
        XCTAssertEqual(controller.presentation, .cards)
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

    func testShowCardsDuringAuthenticationLeavesLoginWebViewRevealed() async {
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in "{\"outcome\":\"authenticationRequired\",\"items\":[]}" }
        )
        controller.apply(.items([summary(index: 3)]), generation: 0)
        controller.refresh()
        await waitForSettled(controller)

        controller.showCardsIfAvailable()

        XCTAssertEqual(controller.presentation, .browser)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertFalse(controller.canShowCards)
    }

    func testShowCardsFromFailureStateReturnsToCardsAndRetries() async {
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"unsupported\",\"items\":[]}" }
        )

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .unsupportedPage)

        controller.showBrowser()
        XCTAssertEqual(loads.value, 1)

        controller.showCardsIfAvailable()

        XCTAssertEqual(controller.presentation, .cards, "A failure state must still return to the card surface")
        XCTAssertTrue(controller.isRefreshing, "The failed list must be re-extracted")
        await waitForSettled(controller)

        XCTAssertEqual(loads.value, 2, "Exactly one recovery pass ran")
        XCTAssertEqual(controller.state, .unsupportedPage)
    }

    func testShowCardsDuringInFlightWorkRevealsProgressWithoutRestarting() async {
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"items\",\"items\":[{\"url\":\"https://gitlab.example.test/p0/-/merge_requests/0\",\"iid\":\"0\",\"title\":\"Fixture 0\"}]}" }
        )

        controller.refresh()
        XCTAssertEqual(controller.state, .loadingPage, "Extraction has not settled yet")

        controller.showBrowser()
        controller.showCardsIfAvailable()

        XCTAssertEqual(controller.presentation, .cards, "In-flight work is revealed as progress in card mode")
        await waitForSettled(controller)

        XCTAssertEqual(loads.value, 1, "Revealing progress must not restart extraction")
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
        XCTAssertFalse(controller.isRefreshing)
    }

    func testStartIfNeededLoadsAfterURLAppearsOnPreviouslyEmptyController() async {
        var activeProvider = ""
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" },
            provider: { activeProvider }
        )

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .unconfigured)
        XCTAssertEqual(loads.value, 0)

        activeProvider = "https://gitlab.example.test/review-list"
        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
        XCTAssertEqual(loads.value, 1)
    }

    // MARK: - Resume after navigation

    func testCancelDuringLoadThenAppearResumesExtraction() async {
        let loadGate = ContinuationGate<Bool>()
        let extractGate = ContinuationGate<String?>()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in await loadGate.wait() },
            executor: { _ in await extractGate.wait() }
        )

        controller.startIfNeeded()
        await waitUntil { loadGate.pendingCount == 1 }
        XCTAssertEqual(controller.state, .loadingPage)
        XCTAssertTrue(controller.isRefreshing)

        controller.cancelPendingWork()
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertTrue(controller.isSuspended)
        XCTAssertTrue(controller.needsExtraction)
        XCTAssertEqual(controller.state, .loadingPage, "Cancelled first load must not look complete")

        loadGate.resume(true)
        await Task.yield()
        XCTAssertNotEqual(controller.state.retainedItems.count, 3, "Cancelled load must not apply later")
        guard case .loadingPage = controller.state else {
            return XCTFail("Late cancelled load must leave the incomplete skeleton, got \(controller.state)")
        }

        controller.startIfNeeded()
        XCTAssertTrue(controller.isRefreshing)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertFalse(controller.needsExtraction)
        await waitUntil { loadGate.pendingCount == 1 }

        loadGate.resume(true)
        await waitUntil { extractGate.pendingCount == 1 }
        extractGate.resume(itemsJSON(count: 3))
        await waitForSettled(controller)

        guard case .loaded(let items, _) = controller.state else {
            return XCTFail("Expected resumed load to complete, got \(controller.state)")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertFalse(controller.needsExtraction)
        XCTAssertFalse(controller.isSuspended)
    }

    func testURLChangeWhileAbsentLoadsNewSourceAndRejectsLatePriorResult() async {
        let loadGate = ContinuationGate<Bool>()
        let extractGate = ContinuationGate<String?>()
        var loadedURLs: [URL] = []
        var activeProvider = "https://gitlab.example.test/list-a"
        let controller = makeController(
            page: makePage(),
            loader: { _, request in
                if let url = request.url {
                    loadedURLs.append(url)
                }
                return await loadGate.wait()
            },
            executor: { _ in await extractGate.wait() },
            provider: { activeProvider }
        )

        controller.startIfNeeded()
        await waitUntil { loadGate.pendingCount == 1 }
        let firstGeneration = controller.currentGeneration
        XCTAssertEqual(loadedURLs.map(\.absoluteString), ["https://gitlab.example.test/list-a"])

        loadGate.resume(true)
        await waitUntil { extractGate.pendingCount == 1 }
        XCTAssertEqual(controller.state, .extracting)

        controller.cancelPendingWork()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertGreaterThan(controller.currentGeneration, firstGeneration)

        activeProvider = "https://gitlab.example.test/list-b"
        extractGate.resume(itemsJSON(count: 1))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state.retainedItems, [], "A's late extraction must not apply after cancel")
        XCTAssertEqual(controller.state, .extracting)

        controller.startIfNeeded()
        await waitUntil { loadGate.pendingCount == 1 }
        let secondGeneration = controller.currentGeneration
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(loadedURLs.map(\.lastPathComponent), ["list-a", "list-b"])
        XCTAssertEqual(controller.state, .loadingPage, "B must not keep A's extracting/cards state")

        loadGate.resume(true)
        await waitUntil { extractGate.pendingCount == 1 }
        extractGate.resume(itemsJSON(count: 5))
        await waitForSettled(controller)

        guard case .loaded(let items, _) = controller.state else {
            return XCTFail("Expected list B to load, got \(controller.state)")
        }
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(controller.currentGeneration, secondGeneration)
        controller.apply(.items([summary(index: 9)]), generation: firstGeneration)
        XCTAssertEqual(controller.state.retainedItems.count, 5, "An older generation must not replace B")
    }

    func testClearingConfigurationStopsRefreshing() async {
        let loadGate = ContinuationGate<Bool>()
        var activeProvider: String? = configuredURLString
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in await loadGate.wait() },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" },
            provider: { activeProvider }
        )

        controller.refresh()
        XCTAssertTrue(controller.isRefreshing)
        await waitUntil { loadGate.pendingCount == 1 }

        activeProvider = ""
        controller.configurationChanged()
        XCTAssertEqual(controller.state, .unconfigured)
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertFalse(controller.needsExtraction)
        XCTAssertFalse(controller.isSuspended)

        loadGate.resume(true)
        await Task.yield()
        XCTAssertEqual(controller.state, .unconfigured)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testReopeningCompleteUnchangedPanelPreservesCards() async {
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { [weak self] _ in self?.itemsJSON(count: 2) }
        )

        controller.startIfNeeded()
        await waitForSettled(controller)
        let preserved = controller.state
        XCTAssertEqual(loads.value, 1)

        controller.cancelPendingWork()
        XCTAssertFalse(controller.needsExtraction)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(controller.state, preserved)

        controller.startIfNeeded()
        await Task.yield()
        XCTAssertEqual(loads.value, 1, "A complete unchanged panel must not reload")
        XCTAssertEqual(controller.state, preserved)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testLateExtractorResultAfterGenerationBumpIsIgnored() async {
        let loadGate = ContinuationGate<Bool>()
        let extractGate = ContinuationGate<String?>()
        var activeProvider = "https://gitlab.example.test/list-a"
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in await loadGate.wait() },
            executor: { _ in await extractGate.wait() },
            provider: { activeProvider }
        )

        controller.startIfNeeded()
        await waitUntil { loadGate.pendingCount == 1 }
        loadGate.resume(true)
        await waitUntil { extractGate.pendingCount == 1 }
        let firstGeneration = controller.currentGeneration
        XCTAssertEqual(controller.state, .extracting)

        activeProvider = "https://gitlab.example.test/list-b"
        controller.configurationChanged()
        let secondGeneration = controller.currentGeneration
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(controller.state, .loadingPage, "Changing source must drop A's cards")

        extractGate.resume(itemsJSON(count: 1))
        await waitUntil { loadGate.pendingCount == 1 }
        loadGate.resume(true)
        await waitUntil { extractGate.pendingCount == 1 }

        XCTAssertEqual(controller.state.retainedItems, [], "Generation \(firstGeneration) must not win after \(secondGeneration)")
        extractGate.resume(itemsJSON(count: 4))
        await waitForSettled(controller)

        XCTAssertEqual(controller.state.retainedItems.count, 4)
        XCTAssertEqual(controller.currentGeneration, secondGeneration)
        controller.apply(.empty, generation: firstGeneration)
        XCTAssertEqual(controller.state.retainedItems.count, 4)
    }

    // MARK: - startOrRefresh

    /// Opening a card mid-extraction cancels the in-flight list extraction;
    /// the late payload must never scrape MR-detail DOM into list cards.
    func testOpenCancelsInFlightExtractionAndRejectsLatePayload() async {
        let extractGate = ContinuationGate<String?>()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in await extractGate.wait() }
        )

        controller.startIfNeeded()
        await waitUntil { extractGate.pendingCount == 1 }
        XCTAssertEqual(controller.state, .extracting)
        let generationBefore = controller.currentGeneration

        controller.open(summary(index: 3))

        XCTAssertEqual(controller.presentation, .browser)
        XCTAssertFalse(controller.isRefreshing, "Ordinary navigation cancels in-flight work")
        XCTAssertGreaterThan(controller.currentGeneration, generationBefore)
        XCTAssertTrue(controller.needsExtraction, "Cancelled first load resumes on next appearance")

        extractGate.resume(itemsJSON(count: 3))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state.retainedItems, [], "A late payload after open must not become cards")
        XCTAssertTrue(Self.isIncompleteForTest(controller.state))
    }

    /// While sign-in recovery owns the retained page, startOrRefresh must
    /// observe instead of force-reloading the list URL over an active SSO.
    func testStartOrRefreshDuringActiveSignInDoesNotReload() async {
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"authenticationRequired\",\"items\":[]}" }
        )

        controller.startOrRefresh()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertTrue(controller.wantsAuthenticationObservation)
        XCTAssertEqual(loads.value, 1)

        controller.startOrRefresh()

        XCTAssertEqual(loads.value, 1, "Sign-in observation must not be interrupted by a forced reload")
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertTrue(controller.wantsAuthenticationObservation)
    }

    private static func isIncompleteForTest(_ state: MergeRequestListPanelState) -> Bool {
        switch state {
        case .loadingPage, .extracting: return true
        default: return false
        }
    }

    func testStartOrRefreshDoesNotDoubleFirstLoad() async {
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" }
        )

        controller.startOrRefresh()
        await waitForSettled(controller)
        XCTAssertEqual(loads.value, 1)
        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
    }

    func testStartOrRefreshReloadsWhenAlreadyComplete() async {
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" }
        )

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(loads.value, 1)

        controller.startOrRefresh()
        await waitForSettled(controller)
        XCTAssertEqual(loads.value, 2)
    }

    func testStartOrRefreshResumesSuspendedLoadOnce() async {
        let loadGate = ContinuationGate<Bool>()
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return await loadGate.wait()
            },
            executor: { _ in "{\"outcome\":\"empty\",\"items\":[]}" }
        )

        controller.startIfNeeded()
        await waitUntil { loadGate.pendingCount == 1 }
        XCTAssertEqual(loads.value, 1)
        controller.cancelPendingWork()
        loadGate.resume(true)

        controller.startOrRefresh()
        await waitUntil { loadGate.pendingCount == 1 }
        XCTAssertEqual(loads.value, 2, "Resume plus startOrRefresh must not stack a third load")
        loadGate.resume(true)
        await waitForSettled(controller)
        XCTAssertEqual(loads.value, 2)
        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
    }

    // MARK: - Authentication recovery

    func testCompletedSignInNavigationWithRowsRestoresCards() async {
        let events = NavigationEventBox()
        var payload = "{\"outcome\":\"authenticationRequired\",\"items\":[]}"
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in payload },
            navigationEvents: events.stream
        )

        controller.apply(.items([summary(index: 1)]), generation: 0)
        controller.refresh()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(controller.presentation, .browser)
        XCTAssertEqual(loads.value, 1)
        XCTAssertEqual(controller.hiddenItems, [summary(index: 1)])
        await waitUntil { events.isSubscribed }

        payload = itemsJSON(count: 2)
        events.yield(.finished)
        await waitUntil {
            if case .loaded = controller.state { return true }
            return false
        }

        guard case .loaded(let items, _) = controller.state else {
            return XCTFail("Expected restored cards, got \(controller.state)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(controller.presentation, .cards)
        XCTAssertTrue(controller.hiddenItems.isEmpty)
        XCTAssertFalse(controller.wantsAuthenticationObservation)
        XCTAssertTrue(controller.canShowCards)
        XCTAssertEqual(loads.value, 1, "Sign-in recovery must not reload the page")
    }

    func testCompletedSignInNavigationWithEmptyListOffersCards() async {
        var payload = "{\"outcome\":\"authenticationRequired\",\"items\":[]}"
        let loads = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in payload }
        )

        controller.refresh()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(controller.presentation, .browser)
        XCTAssertFalse(controller.canShowCards)

        payload = "{\"outcome\":\"empty\",\"items\":[]}"
        controller.handleObservedNavigation(.finished)
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
        XCTAssertEqual(controller.presentation, .cards)
        XCTAssertTrue(controller.canShowCards)
        XCTAssertFalse(controller.wantsAuthenticationObservation)
        XCTAssertEqual(loads.value, 1, "Empty-list recovery must not reload the page")
    }

    func testNewNavigationCancelsOldPostSignInExtraction() async {
        let extractGate = ContinuationGate<String?>()
        let extractCount = CounterBox()
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in
                extractCount.increment()
                return await extractGate.wait()
            }
        )

        controller.startIfNeeded()
        await waitUntil { extractGate.pendingCount == 1 }
        extractGate.resume("{\"outcome\":\"authenticationRequired\",\"items\":[]}")
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(extractCount.value, 1)

        controller.handleObservedNavigation(.finished)
        await waitUntil { extractGate.pendingCount == 1 }
        let firstPostSignInGeneration = controller.currentGeneration
        XCTAssertTrue(controller.isRefreshing)

        controller.handleObservedNavigation(.startedProvisionalNavigation)
        XCTAssertGreaterThan(controller.currentGeneration, firstPostSignInGeneration)
        XCTAssertFalse(controller.isRefreshing)

        extractGate.resume(itemsJSON(count: 4))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state, .authenticationRequired, "Cancelled extraction must not restore cards")
        XCTAssertEqual(controller.state.retainedItems, [])

        controller.handleObservedNavigation(.finished)
        await waitUntil { extractGate.pendingCount == 1 }
        extractGate.resume("{\"outcome\":\"empty\",\"items\":[]}")
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
        XCTAssertEqual(controller.presentation, .cards)
        XCTAssertEqual(extractCount.value, 3)
    }

    func testUnsupportedPageDuringSignInRecoveryLeavesBrowserUsable() async {
        var payload = "{\"outcome\":\"authenticationRequired\",\"items\":[]}"
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in payload },
            readinessAttempts: 1
        )
        controller.apply(.items([summary(index: 8)]), generation: 0)
        controller.refresh()
        await waitForSettled(controller)
        XCTAssertEqual(controller.hiddenItems, [summary(index: 8)])

        payload = "{\"outcome\":\"unsupported\",\"items\":[]}"
        controller.handleObservedNavigation(.finished)
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .unsupportedPage)
        XCTAssertEqual(controller.presentation, .browser, "The same-origin page must remain usable")
        XCTAssertTrue(controller.wantsAuthenticationObservation)
        XCTAssertEqual(controller.hiddenItems, [summary(index: 8)])
        XCTAssertFalse(controller.canShowCards)
        XCTAssertEqual(controller.state.retainedItems, [])
    }

    func testOrdinaryFailureAfterSignInRestoresLabelledStaleCards() async {
        var payload = "{\"outcome\":\"authenticationRequired\",\"items\":[]}"
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in true },
            executor: { _ in payload }
        )
        controller.apply(.items([summary(index: 2)]), generation: 0)
        controller.refresh()
        await waitForSettled(controller)
        XCTAssertEqual(controller.hiddenItems, [summary(index: 2)])

        payload = "definitely not json"
        controller.handleObservedNavigation(.finished)
        await waitForSettled(controller)

        guard case .stale(let items, let refreshedAt, let reason) = controller.state else {
            return XCTFail("Expected labelled stale cards, got \(controller.state)")
        }
        XCTAssertEqual(items, [summary(index: 2)])
        XCTAssertEqual(refreshedAt, currentDate)
        XCTAssertEqual(reason, .extractionFailed)
        XCTAssertEqual(controller.presentation, .cards)
        XCTAssertTrue(controller.hiddenItems.isEmpty)
        XCTAssertFalse(controller.wantsAuthenticationObservation)
    }

    func testCancelDuringSignInWatchResumesObservationWithoutReload() async {
        let loads = CounterBox()
        let events = NavigationEventBox()
        var payload = "{\"outcome\":\"authenticationRequired\",\"items\":[]}"
        let controller = makeController(
            page: makePage(),
            loader: { _, _ in
                loads.increment()
                return true
            },
            executor: { _ in payload },
            navigationEvents: events.stream
        )

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(loads.value, 1)
        XCTAssertTrue(controller.wantsAuthenticationObservation)

        controller.cancelPendingWork()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertTrue(controller.needsExtraction)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(controller.presentation, .browser)

        payload = itemsJSON(count: 1)
        controller.startIfNeeded()
        await waitForSettled(controller)

        XCTAssertEqual(loads.value, 1, "Resuming sign-in observation must not reload the page")
        guard case .loaded(let items, _) = controller.state else {
            return XCTFail("Expected resumed DOM extraction, got \(controller.state)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(controller.presentation, .cards)
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

@MainActor
private final class ContinuationGate<Value> {
    private var pending: [CheckedContinuation<Value, Never>] = []

    var pendingCount: Int { pending.count }

    func wait() async -> Value {
        await withCheckedContinuation { pending.append($0) }
    }

    func resume(_ value: Value) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: value)
    }
}

@MainActor
private final class NavigationEventBox {
    private let pair = AsyncStream.makeStream(of: WebPage.NavigationEvent.self)

    var isSubscribed: Bool { true }

    func stream(_ page: WebPage) -> AsyncStream<WebPage.NavigationEvent> {
        pair.stream
    }

    func yield(_ event: WebPage.NavigationEvent) {
        pair.continuation.yield(event)
    }
}
