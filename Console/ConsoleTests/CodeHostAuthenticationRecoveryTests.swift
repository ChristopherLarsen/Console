import XCTest
import WebKit
@testable import Console

/// Synthetic WebKit fixtures for GitLab sign-in recovery. Every URL, title,
/// and name is invented. No live GitLab, no credentials, no cookies, and no
/// company DOM.
@MainActor
final class CodeHostAuthenticationRecoveryTests: XCTestCase {

    private let listURL = URL(string: "https://gitlab.example.test/dashboard/merge_requests")!
    private var currentDate = Date(timeIntervalSince1970: 1_787_100_000)

    private var authHTML: String {
        """
        <html><body>
        <form id="new_user" action="/users/sign_in">
          <input name="user[login]">
          <input name="user[password]" type="password">
        </form>
        </body></html>
        """
    }

    private var listHTML: String {
        """
        <html><body>
        <ul class="merge_requests-list" id="merge_requests_list">
          <li class="merge-request" data-testid="merge-request">
            <a href="https://gitlab.example.test/group/console-ios/-/merge_requests/11">Recovered fixture change</a>
          </li>
          <li class="merge-request" data-testid="merge-request">
            <a href="https://gitlab.example.test/group/terminal-bridge/-/merge_requests/4">Second recovered row</a>
          </li>
        </ul>
        </body></html>
        """
    }

    private var emptyHTML: String {
        """
        <html><body>
        <div class="empty-state"><h4>No merge requests</h4></div>
        </body></html>
        """
    }

    private var unsupportedHTML: String {
        """
        <html><body>
        <h1>Project wiki</h1>
        <p>Some other same-origin page entirely.</p>
        </body></html>
        """
    }

    private func makePage() -> WebPage {
        CodeHostWebSessionStore.makePage(dataStore: WKWebsiteDataStore.nonPersistent())
    }

    private func makeController(
        page: WebPage,
        html: FixtureHTML
    ) -> CodeHostListPanelController {
        CodeHostListPanelController(
            kind: .reviewsRequested,
            page: page,
            configuredURLStringProvider: { [listURL] in listURL.absoluteString },
            now: { [weak self] in self?.currentDate ?? Date() },
            readinessAttempts: 8,
            readinessIntervalNanoseconds: 50_000_000,
            pageLoader: { page, request in
                await Self.loadSimulated(page: page, request: request, html: html.value)
            }
        )
    }

    @discardableResult
    private static func loadSimulated(page: WebPage, request: URLRequest, html: String) async -> Bool {
        let events = page.load(simulatedRequest: request, responseHTML: html)
        do {
            for try await event in events {
                if case .finished = event { return true }
            }
        } catch {
            return false
        }
        return false
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func waitForSettled(_ controller: CodeHostListPanelController) async {
        await waitUntil { !controller.isRefreshing }
    }

    func testLoadedCardsThenAuthenticationRevealsLoginWebView() async {
        let html = FixtureHTML(authHTML)
        let page = makePage()
        let controller = makeController(page: page, html: html)

        controller.apply(
            .items([
                MergeRequestSummary(
                    id: URL(string: "https://gitlab.example.test/group/console-ios/-/merge_requests/3")!,
                    iidText: "3",
                    title: "Prior fixture row",
                    projectDisplayName: nil,
                    authorDisplayName: nil,
                    isDraft: false,
                    pipelineDisplayState: nil,
                    reviewDisplayState: nil,
                    updatedText: nil,
                    mergeRequestURL: URL(string: "https://gitlab.example.test/group/console-ios/-/merge_requests/3")!,
                    sourceOrder: 0
                )
            ]),
            generation: 0
        )
        XCTAssertEqual(controller.presentation, .cards)

        controller.refresh()
        await waitForSettled(controller)

        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(controller.presentation, .browser)
        XCTAssertFalse(controller.canShowCards)
        XCTAssertEqual(controller.hiddenItems.count, 1)
        XCTAssertEqual(controller.state.retainedItems, [])
        XCTAssertTrue(controller.wantsAuthenticationObservation)
    }

    func testCompletedSignInNavigationExtractsRowsFromSyntheticDOM() async {
        let html = FixtureHTML(authHTML)
        let page = makePage()
        let controller = makeController(page: page, html: html)

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .authenticationRequired)
        XCTAssertEqual(controller.presentation, .browser)
        await waitUntil { controller.isObservingSignInNavigations }
        try? await Task.sleep(nanoseconds: 100_000_000)

        html.value = listHTML
        let finished = await Self.loadSimulated(
            page: page,
            request: URLRequest(url: listURL),
            html: listHTML
        )
        XCTAssertTrue(finished)

        await waitUntil {
            if case .loaded = controller.state { return true }
            return false
        }
        guard case .loaded(let items, _) = controller.state else {
            return XCTFail("Expected cards after sign-in navigation, got \(controller.state)")
        }
        XCTAssertEqual(items.map(\.title), ["Recovered fixture change", "Second recovered row"])
        XCTAssertEqual(controller.presentation, .cards)
        XCTAssertTrue(controller.canShowCards)
        XCTAssertFalse(controller.wantsAuthenticationObservation)
    }

    func testCompletedSignInNavigationRecognizesEmptyList() async {
        let html = FixtureHTML(authHTML)
        let page = makePage()
        let controller = makeController(page: page, html: html)

        controller.startIfNeeded()
        await waitForSettled(controller)
        XCTAssertEqual(controller.state, .authenticationRequired)
        await waitUntil { controller.isObservingSignInNavigations }
        try? await Task.sleep(nanoseconds: 100_000_000)

        html.value = emptyHTML
        _ = await Self.loadSimulated(
            page: page,
            request: URLRequest(url: listURL),
            html: emptyHTML
        )

        await waitUntil {
            if case .empty = controller.state { return true }
            return false
        }
        XCTAssertEqual(controller.state, .empty(refreshedAt: currentDate))
        XCTAssertEqual(controller.presentation, .cards)
        XCTAssertTrue(controller.canShowCards)
    }

    func testSameOriginUnsupportedPageStaysUsableAfterSignInNavigation() async {
        let html = FixtureHTML(authHTML)
        let page = makePage()
        let controller = makeController(page: page, html: html)

        controller.startIfNeeded()
        await waitForSettled(controller)
        await waitUntil { controller.isObservingSignInNavigations }
        try? await Task.sleep(nanoseconds: 100_000_000)

        html.value = unsupportedHTML
        _ = await Self.loadSimulated(
            page: page,
            request: URLRequest(url: URL(string: "https://gitlab.example.test/group/console-ios/wikis/home")!),
            html: unsupportedHTML
        )

        await waitUntil { controller.state == .unsupportedPage || controller.presentation == .browser && !controller.isRefreshing }

        XCTAssertEqual(controller.presentation, .browser, "Unsupported same-origin page must remain usable")
        XCTAssertTrue(controller.wantsAuthenticationObservation)
        XCTAssertFalse(controller.canShowCards)
        XCTAssertEqual(controller.state.retainedItems, [])
    }
}

@MainActor
private final class FixtureHTML {
    var value: String
    init(_ value: String) { self.value = value }
}
