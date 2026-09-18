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
        now: (() -> Date)? = nil,
        pageReloader: (@MainActor (WebPage) -> Void)? = nil
    ) -> (BrowserTabStore, [WebPage]) {
        let pages = (0..<max(pinnedCount, 1)).map { _ in makePage() }
        let store = BrowserTabStore(
            pinnedTabs: pages.map { (page: $0, title: "Pinned \($0)") },
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

    func testNewTabClipboardNavigationAndBlankFocusRequest() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (store, pages) = makeStore()
        pasteboard.setString("ordinary clipboard text", forType: .string)
        store.createTabFromUserAction(pasteboard: pasteboard)
        XCTAssertNil(store.activePage.url)
        XCTAssertEqual(store.newTabInputID, store.activeTabID)
        XCTAssertNil(store.newTabInputURL)
        store.finishNewTabInput(for: store.activeTabID)
        XCTAssertNil(store.newTabInputID)

        pasteboard.clearContents()
        pasteboard.setString(" https://example.test/browse/ENG-42?view=full#notes\n", forType: .string)
        store.createTabFromUserAction(pasteboard: pasteboard)
        XCTAssertEqual(store.activePage.url?.absoluteString, "https://example.test/browse/ENG-42?view=full#notes")
        XCTAssertEqual(store.newTabInputURL, store.activePage.url)
        XCTAssertNil(pages[0].url)
        store.select(store.tabs[0].id)
        XCTAssertNil(store.newTabInputID)

        while store.canOpenTab { store.openTab() }
        store.createTabFromUserAction(pasteboard: pasteboard)
        XCTAssertEqual(store.tabs.count, BrowserTabStore.maxTabs)
        XCTAssertNil(store.newTabInputID)
    }

    func testClipboardAutoNavigationRejectsNonWebContent() {
        for text in ["", "see https://example.test", "https://one.test\nhttps://two.test",
                     "javascript:alert(1)", "file:///tmp/a", "mailto:me@example.test", "https://", "some words"] {
            XCTAssertNil(BrowserTabStore.clipboardURL(from: text), text)
        }
        XCTAssertEqual(BrowserTabStore.clipboardURL(from: "https://example.test/a")?.host, "example.test")
        XCTAssertEqual(BrowserTabStore.clipboardURL(from: "http://localhost:8080/a")?.port, 8080)
    }

    func testNotificationAlwaysOpensFreshTabEvenAtCap() {
        let (store, pages) = makeStore(pinnedCount: 2)
        while store.canOpenTab { store.openTab() }
        store.select(store.tabs[0].id)
        let previousIDs = store.tabs.map(\.id)
        let url = URL(string: "https://example.test/team/project/-/merge_requests/1")!
        let first = store.openNotificationTab(url: url)
        XCTAssertEqual(store.tabs.count, previousIDs.count + 1)
        XCTAssertEqual(store.activeTabID, first.id)
        XCTAssertEqual(first.page.url, url)
        XCTAssertNil(pages[0].url)
        let second = store.openNotificationTab(url: url)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.activeTabID, second.id)
        XCTAssertEqual(Array(store.tabs.prefix(previousIDs.count)).map(\.id), previousIDs)
    }

    func testOpenTabAppendsActivatesAndStaysBlank() {
        let (store, _) = makeStore(pinnedCount: 1)

        let tab = store.openTab()

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertFalse(tab.isPinned)
        XCTAssertEqual(store.tabs[1].titleOverride, nil)
        // New tabs are blank: no URL is loaded and the strip falls back to
        // its "New Tab" placeholder title.
        XCTAssertNil(tab.page.url)
        XCTAssertEqual(tab.displayTitle, "New Tab")
    }

    func testOpenTabWithURLAppendsActivatesAndLoadsGivenURL() throws {
        let issueURL = URL(string: "https://example.test/browse/ENG-1")!
        let (store, _) = makeStore(pinnedCount: 1)

        let tab = store.openTab(url: issueURL)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertFalse(tab.isPinned)
        let requested = try XCTUnwrap(tab.page.url)
        XCTAssertEqual(requested, issueURL)
        // A deep link must never touch the pinned page; only the new tab
        // navigates.
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

        // One minute after the dynamic tab was opened the pinned tab has aged
        // out (6 min) while the young dynamic tab stays.
        clock.advance(by: 1 * 60)
        let firstPass = store.reloadStaleTabs()
        XCTAssertEqual(firstPass.map(\.id), [store.tabs[0].id])
        XCTAssertFalse(reloaded().contains(ObjectIdentifier(dynamic.page)))

        // Once the dynamic tab itself passes the window it reloads too.
        clock.advance(by: 4 * 60)
        let secondPass = store.reloadStaleTabs()
        XCTAssertEqual(secondPass.map(\.id), [dynamic.id])
    }

    func testReloadStaleTabsSkippedYoungTabKeepsOwnStampUntilItAges() {
        let (store, _, clock, reloaded) = makeReloadFixture()
        clock.advance(by: 5 * 60)
        let dynamic = store.openTab()

        // The pinned tab has aged out, but the 4-minute-old dynamic tab is
        // skipped and keeps its creation stamp.
        clock.advance(by: 4 * 60)
        store.reloadStaleTabs()
        XCTAssertEqual(reloaded().count, 1)

        // Two minutes later the dynamic tab has reached the window and
        // reloads; the freshly stamped pinned tab does not.
        clock.advance(by: 2 * 60)
        let reloadedTabs = store.reloadStaleTabs()
        XCTAssertEqual(reloadedTabs.map(\.id), [dynamic.id])
    }
}
