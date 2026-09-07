import XCTest
import WebKit
@testable import Console

/// Verifies the two-page session assumption both hosted panels depend on:
///
/// 1. Both pages are constructed with the SAME explicit persistent
///    `WKWebsiteDataStore` (so a normal sign-in in one page is visible to the
///    other through shared website data).
/// 2. Their back-forward navigation histories stay independent.
/// 3. The store is one stable process-wide instance.
///
/// The cookie probe below uses one synthetic, valueless cookie on an invented
/// host inside a NON-persistent store. No real credentials, cookies, or site
/// data are ever read, copied, or persisted.
@MainActor
final class CodeHostWebSessionStoreTests: XCTestCase {

    // MARK: - Structure

    func testSharedSingletonUsesTheDefaultPersistentDataStore() {
        let store = CodeHostWebSessionStore.shared
        XCTAssertTrue(store.websiteDataStore.isPersistent, "The shared store must be persistent")
        XCTAssertTrue(store.websiteDataStore === WKWebsiteDataStore.default(), "Production pages share the default persistent store")
    }

    func testBothPagesAreDistinctInstances() {
        let store = CodeHostWebSessionStore.shared
        XCTAssertFalse(store.reviewsPage === store.authoredPage, "Each list kind owns its own page and history")
    }

    func testSharedIsOneStableProcessWideInstance() {
        let first = CodeHostWebSessionStore.shared
        let again = CodeHostWebSessionStore.shared
        XCTAssertTrue(first === again, "The shared store must be a stable process-wide instance")
        XCTAssertTrue(first.websiteDataStore === WKWebsiteDataStore.default())
    }

    func testInjectedPagesReceiveExactlyOneSharedDataStore() {
        let injectedStore = WKWebsiteDataStore.nonPersistent()
        var capturedStores: [WKWebsiteDataStore] = []

        _ = CodeHostWebSessionStore(
            dataStore: injectedStore,
            pageProvider: { dataStore in
                capturedStores.append(dataStore)
                return CodeHostWebSessionStore.makePage(dataStore: dataStore)
            }
        )

        XCTAssertEqual(capturedStores.count, 2)
        XCTAssertTrue(
            capturedStores[0] === capturedStores[1],
            "Both pages must be configured with the same data store instance"
        )
        XCTAssertTrue(capturedStores[0] === injectedStore)
    }

    // MARK: - Shared website data (synthetic probe, nonpersistent store)

    func testBothPagesSeeSiteDataSharedThroughOneStore() async throws {
        let sharedStore = WKWebsiteDataStore.nonPersistent()
        let store = CodeHostWebSessionStore(dataStore: sharedStore)

        // Synthetic, credential-free probe on an invented host.
        guard let probeCookie = HTTPCookie(
            properties: [
                .domain: ".gitlab.probe.invalid",
                .path: "/",
                .name: "console-shared-store-probe",
                .value: "shared",
            ]
        ) else {
            return XCTFail("Failed to build synthetic probe cookie")
        }

        await sharedStore.httpCookieStore.setCookie(probeCookie)

        let reviewsSawProbe = try await pageSeesProbe(store.reviewsPage)
        let authoredSawProbe = try await pageSeesProbe(store.authoredPage)

        XCTAssertTrue(reviewsSawProbe, "Reviews page should observe site data from the shared store")
        XCTAssertTrue(authoredSawProbe, "Authored page should observe the same shared site data")
    }

    /// Loads blank content under the probe origin and reads `document.cookie`
    /// through the rendered page only.
    private func pageSeesProbe(_ page: WebPage) async throws -> Bool {
        _ = try await navigateToFinished(
            page.load(
                html: "<html><body>probe</body></html>",
                baseURL: URL(string: "https://gitlab.probe.invalid/")!
            )
        )
        guard let raw = try await page.callJavaScript("return document.cookie;") as? String else {
            return false
        }
        return raw.contains("console-shared-store-probe=shared")
    }

    // MARK: - Independent navigation histories

    func testBackForwardListsStayIndependent() async throws {
        let store = CodeHostWebSessionStore(dataStore: WKWebsiteDataStore.nonPersistent())
        let reviewsPage = store.reviewsPage
        let authoredPage = store.authoredPage

        let reviewsListURL = URL(string: "https://gitlab.history.invalid/-/merge_requests/reviews")!
        let reviewsMRURL = URL(string: "https://gitlab.history.invalid/group/a/-/merge_requests/1")!
        let authoredListURL = URL(string: "https://gitlab.history.invalid/-/merge_requests/authored")!

        try await simulateLoad(reviewsPage, url: reviewsListURL, body: "reviews list")
        try await simulateLoad(authoredPage, url: authoredListURL, body: "authored list")

        XCTAssertEqual(reviewsPage.url, reviewsListURL)
        XCTAssertEqual(authoredPage.url, authoredListURL)

        // Navigate the reviews page to an MR detail; the authored page must
        // not move.
        try await simulateLoad(reviewsPage, url: reviewsMRURL, body: "mr detail")

        XCTAssertEqual(reviewsPage.url, reviewsMRURL)
        XCTAssertEqual(authoredPage.url, authoredListURL, "Authored history must stay untouched by reviews navigation")

        XCTAssertEqual(reviewsPage.backForwardList.currentItem?.url, reviewsMRURL)
        XCTAssertEqual(authoredPage.backForwardList.currentItem?.url, authoredListURL)

        XCTAssertTrue(
            reviewsPage.backForwardList.backList.contains { $0.url == reviewsListURL },
            "Reviews page keeps its own back entry"
        )
        XCTAssertTrue(
            authoredPage.backForwardList.backList.isEmpty,
            "Authored page never gained the reviews page's entries"
        )
    }

    // MARK: - Optimistic load record

    func testLoadIfNeededRecordsURLSynchronously() {
        let store = CodeHostWebSessionStore(dataStore: WKWebsiteDataStore.nonPersistent())
        let url = URL(string: "https://gitlab.probe.invalid/-/merge_requests/list")!

        store.loadIfNeeded(.reviewsRequested, url: url)

        XCTAssertEqual(store.recordedURLString(for: .reviewsRequested), url.absoluteString)
    }

    func testFailedFirstLoadDoesNotBlockRetry() async {
        let store = CodeHostWebSessionStore(dataStore: WKWebsiteDataStore.nonPersistent())
        let url = URL(string: "https://console-load-failure.invalid/unreachable")!

        store.loadIfNeeded(.authored, url: url)

        // The record was written before the load ran; the failed load must
        // clear it so the same URL can be requested again.
        let deadline = Date().addingTimeInterval(10)
        while store.recordedURLString(for: .authored) == url.absoluteString, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(store.recordedURLString(for: .authored), "A load that never finished must not permanently skip its URL")

        // Second request with force=false issues a new load (record was cleared).
        store.loadIfNeeded(.authored, url: url)
        XCTAssertEqual(store.recordedURLString(for: .authored), url.absoluteString)
    }

    // MARK: - Plumbing

    private func simulateLoad(_ page: WebPage, url: URL, body: String) async throws {
        try await navigateToFinished(
            page.load(
                simulatedRequest: URLRequest(url: url),
                responseHTML: "<html><body>\(body)</body></html>"
            )
        )
    }

    @discardableResult
    private func navigateToFinished<S>(_ events: S) async throws -> Bool where S: AsyncSequence, S.Element == WebPage.NavigationEvent {
        for try await event in events {
            if case .finished = event { return true }
        }
        return false
    }
}
