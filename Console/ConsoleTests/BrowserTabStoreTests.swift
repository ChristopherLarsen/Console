import XCTest
import WebKit
@testable import Console

/// State-machine tests for the browser-style tab registry shared by the JIRA
/// and GitLab sidebar destinations. Page loads in dynamic tabs are not
/// asserted here beyond the requested URL bookkeeping; WebKit behavior stays
/// out of scope.
@MainActor
final class BrowserTabStoreTests: XCTestCase {

    private func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        return WebPage(configuration: configuration)
    }

    private func makeStore(
        pinnedCount: Int = 1,
        newTabURL: URL? = nil
    ) -> (BrowserTabStore, [WebPage]) {
        let pages = (0..<max(pinnedCount, 1)).map { _ in makePage() }
        let store = BrowserTabStore(
            pinnedTabs: pages.map { (page: $0, title: "Pinned \($0)") },
            newTabURLProvider: { newTabURL }
        )
        return (store, pages)
    }

    // MARK: - Init

    func testInitCreatesPinnedTabsAndActivatesFirst() {
        let (store, pages) = makeStore(pinnedCount: 2)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertTrue(store.tabs.allSatisfy(\.isPinned))
        XCTAssertTrue(store.activeTab.page === pages[0])
    }

    func testDisplayTitlePrefersOverrideOverPageTitle() {
        let (store, _) = makeStore(pinnedCount: 1)
        XCTAssertEqual(store.tabs[0].displayTitle, "Pinned \(store.tabs[0].page)")
        XCTAssertEqual(store.activeTab.displayTitle, store.tabs[0].displayTitle)
    }

    // MARK: - Selection

    func testSelectSwitchesActivePage() {
        let (store, pages) = makeStore(pinnedCount: 2)
        store.select(store.tabs[1].id)
        XCTAssertEqual(store.activeTab.id, store.tabs[1].id)
        XCTAssertTrue(store.activePage === pages[1])
    }

    func testSelectUnknownIDKeepsActiveTab() {
        let (store, _) = makeStore(pinnedCount: 1)
        let original = store.activeTabID
        store.select(UUID())
        XCTAssertEqual(store.activeTabID, original)
    }

    // MARK: - Opening

    func testOpenTabAppendsActivatesAndLoadsProviderURL() throws {
        let url = URL(string: "https://example.test/list")!
        let (store, _) = makeStore(pinnedCount: 1, newTabURL: url)

        let tab = store.openTab()

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertFalse(tab.isPinned)
        XCTAssertEqual(store.tabs[1].titleOverride, nil)
        let requested = try XCTUnwrap(tab.page.url)
        XCTAssertEqual(requested, url)
    }

    func testOpenTabWithoutProviderURLStaysBlank() {
        let (store, _) = makeStore(pinnedCount: 1, newTabURL: nil)
        let tab = store.openTab()
        XCTAssertNil(tab.page.url)
        XCTAssertEqual(store.activeTabID, tab.id)
    }

    func testOpenTabWithURLAppendsActivatesAndLoadsGivenURL() throws {
        let providerURL = URL(string: "https://example.test/list")!
        let issueURL = URL(string: "https://example.test/browse/ENG-1")!
        let (store, _) = makeStore(pinnedCount: 1, newTabURL: providerURL)

        let tab = store.openTab(url: issueURL)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertFalse(tab.isPinned)
        let requested = try XCTUnwrap(tab.page.url)
        XCTAssertEqual(requested, issueURL)
        // The provider URL must never load first and race the deep link; the
        // pinned page is the only thing tracking the list.
        XCTAssertNil(store.tabs[0].page.url)
    }

    func testOpenTabWithURLAtCapNavigatesActiveTab() throws {
        let issueURL = URL(string: "https://example.test/browse/ENG-2")!
        let (store, _) = makeStore(pinnedCount: 1)

        while store.canOpenTab {
            store.openTab()
        }
        let activeBefore = store.activeTabID
        let activePageBefore = store.activePage

        let result = store.openTab(url: issueURL)

        XCTAssertEqual(store.tabs.count, BrowserTabStore.maxTabs)
        XCTAssertEqual(store.activeTabID, activeBefore)
        XCTAssertEqual(result.id, activeBefore)
        XCTAssertTrue(store.activePage === activePageBefore)
        let requested = try XCTUnwrap(store.activePage.url)
        XCTAssertEqual(requested, issueURL)
    }

    func testOpenTabStopsAtCap() {
        let (store, _) = makeStore(pinnedCount: 1)

        while store.canOpenTab {
            store.openTab()
        }
        let activeBefore = store.activeTabID
        let result = store.openTab()

        XCTAssertEqual(store.tabs.count, BrowserTabStore.maxTabs)
        XCTAssertEqual(store.activeTabID, activeBefore)
        XCTAssertEqual(result.id, activeBefore)
        XCTAssertFalse(store.canOpenTab)
    }

    // MARK: - Closing

    func testCloseNonActiveTabKeepsActiveTab() {
        let (store, _) = makeStore(pinnedCount: 1)
        let dynamic = store.openTab()
        store.select(store.tabs[0].id)
        let activeBefore = store.activeTabID

        store.close(dynamic.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTabID, activeBefore)
    }

    func testCloseActiveTabActivatesRightNeighbor() {
        let (store, _) = makeStore(pinnedCount: 2)
        store.select(store.tabs[1].id)
        let dynamic = store.openTab()

        store.close(dynamic.id)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, store.tabs[1].id)
    }

    func testCloseLastTabActivatesClosestRemaining() {
        let (store, _) = makeStore(pinnedCount: 1)
        let dynamic = store.openTab()

        store.close(dynamic.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testClosePinnedTabIsNoOp() {
        let (store, _) = makeStore(pinnedCount: 2)
        let activeBefore = store.activeTabID

        store.close(store.tabs[0].id)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, activeBefore)
        XCTAssertTrue(store.tabs[0].isPinned)
    }

    func testCloseUnknownIDIsNoOp() {
        let (store, _) = makeStore(pinnedCount: 1)
        store.close(UUID())
        XCTAssertEqual(store.tabs.count, 1)
    }
}
