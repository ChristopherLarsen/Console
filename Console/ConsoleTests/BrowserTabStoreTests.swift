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
        newTabURL: URL? = nil,
        now: (() -> Date)? = nil,
        pageReloader: (@MainActor (WebPage) -> Void)? = nil
    ) -> (BrowserTabStore, [WebPage]) {
        let pages = (0..<max(pinnedCount, 1)).map { _ in makePage() }
        let store = BrowserTabStore(
            pinnedTabs: pages.map { (page: $0, title: "Pinned \($0)") },
            newTabURLProvider: { newTabURL },
            now: now ?? { Date() },
            pageReloader: pageReloader
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

    // MARK: - Stale tab reload on entry

    /// Mutable clock so tests can age tabs deterministically.
    private final class Clock {
        private(set) var date: Date
        init(_ date: Date) { self.date = date }
        func advance(by interval: TimeInterval) { date = date.addingTimeInterval(interval) }
    }

    /// Frozen clock + reload recorder shared by the staleness tests.
    private func makeReloadFixture(
        pinnedCount: Int = 1,
        start: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> (store: BrowserTabStore, pages: [WebPage], clock: Clock, reloaded: () -> [ObjectIdentifier]) {
        let clock = Clock(start)
        var reloadedPages: [ObjectIdentifier] = []
        let pages = (0..<max(pinnedCount, 1)).map { _ in makePage() }
        let store = BrowserTabStore(
            pinnedTabs: pages.map { (page: $0, title: "Pinned \($0)") },
            newTabURLProvider: { nil },
            now: { [clock] in clock.date },
            pageReloader: { reloadedPages.append(ObjectIdentifier($0)) }
        )
        return (store, pages, clock, { reloadedPages })
    }

    func testReloadStaleTabsKeepsFreshTabsAndReloadsAgedTabs() {
        let (store, pages, clock, reloaded) = makeReloadFixture(pinnedCount: 2)

        // Fresh store: entry within the window must not reload anything.
        store.reloadStaleTabs()
        XCTAssertTrue(reloaded().isEmpty)

        // Past the window: every tab reloads in place.
        clock.advance(by: 11 * 60)
        let reloadedTabs = store.reloadStaleTabs()

        XCTAssertEqual(Set(reloadedTabs.map(\.id)), Set(store.tabs.map(\.id)))
        XCTAssertEqual(reloaded(), pages.map(ObjectIdentifier.init))

        // The stamps refreshed: an immediate second entry reloads nothing.
        store.reloadStaleTabs()
        XCTAssertEqual(reloaded().count, 2)
    }

    func testReloadStaleTabsSkipsTabsOpenedRecently() {
        let (store, _, clock, reloaded) = makeReloadFixture()
        clock.advance(by: 5 * 60)
        let dynamic = store.openTab()

        // One minute after the dynamic tab was opened: still fresh.
        clock.advance(by: 1 * 60)
        store.reloadStaleTabs()
        XCTAssertFalse(reloaded().contains(ObjectIdentifier(dynamic.page)))

        // Six more minutes (pinned 12 min old, dynamic 7 min old): the aged
        // pinned tab reloads, the young dynamic tab stays.
        clock.advance(by: 6 * 60)
        let reloadedTabs = store.reloadStaleTabs()
        XCTAssertEqual(reloadedTabs.map(\.id), [store.tabs[0].id])
        XCTAssertFalse(reloaded().contains(ObjectIdentifier(dynamic.page)))
        XCTAssertTrue(reloaded().contains(ObjectIdentifier(store.tabs[0].page)))
    }

    func testReloadStaleTabsSkippedYoungTabKeepsOwnStampUntilItAges() {
        let (store, _, clock, reloaded) = makeReloadFixture()
        clock.advance(by: 5 * 60)
        let dynamic = store.openTab()

        // 11 minutes in: pinned reloads; the 6-minute-old dynamic tab is
        // skipped and keeps its creation stamp.
        clock.advance(by: 6 * 60)
        store.reloadStaleTabs()
        XCTAssertEqual(reloaded().count, 1)

        // 14 minutes in: the dynamic tab is 9 minutes old — still skipped.
        clock.advance(by: 3 * 60)
        let reloadedTabs = store.reloadStaleTabs()
        XCTAssertTrue(reloadedTabs.isEmpty)

        // 15 minutes in: the dynamic tab is 10 minutes old and reloads.
        clock.advance(by: 1 * 60)
        let reloadedTabsSecondPass = store.reloadStaleTabs()
        XCTAssertEqual(reloadedTabsSecondPass.map(\.id), [dynamic.id])
    }
}
