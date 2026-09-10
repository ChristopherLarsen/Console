import XCTest
import WebKit
@testable import Console

/// Extraction against hand-written synthetic GitLab-like HTML. No live GitLab
/// login is involved anywhere; every URL, project, title, and name below is
/// invented fixture data.
///
/// Where practical the real JavaScript extractor runs inside a nonpersistent
/// `WebPage`; the Swift decode layer is exercised directly as well.
@MainActor
final class MergeRequestListExtractorTests: XCTestCase {

    // MARK: - Synthetic fixtures (invented data)

    private let baseURLString = "https://gitlab.example.test/dashboard/merge_requests"

    private var fullListHTML: String {
        """
        <html><body>
        <main>
          <ul class="merge_requests-list" id="merge_requests_list">
            <li class="merge-request" data-testid="merge-request">
              <span class="project-name">Console iOS</span>
              <a href="https://gitlab.example.test/group/console-ios/-/merge_requests/123">!123</a>
              <a href="https://gitlab.example.test/group/console-ios/-/merge_requests/123" class="merge-request-title-text">Fix account recovery navigation crash</a>
              <a class="author_link" href="/chen">Alex Chen</a>
              <span class="ci-status-link ci-status-icon-failed" aria-label="Failed"></span>
              <a href="https://gitlab.example.test/group/console-ios/-/milestones/12" class="milestone">24.10</a>
              <time datetime="2026-08-22T10:00:00Z">updated 2h ago</time>
            </li>
            <li class="merge-request" data-testid="merge-request">
              <span class="draft-status">Draft</span>
              <span class="project-name">Terminal Bridge</span>
              <a href="https://gitlab.example.test/group/terminal-bridge/-/merge_requests/7">!7</a>
              <a href="https://gitlab.example.test/group/terminal-bridge/-/merge_requests/7">Rework resize handle gestures</a>
              <a class="author_link" href="/sam">Sam Ortiz</a>
              <time datetime="2026-08-21T09:00:00Z">updated 1d ago</time>
            </li>
            <li class="merge-request" data-testid="merge-request">
              <span class="project-name">Console iOS</span>
              <a href="https://gitlab.example.test/group/console-ios/-/merge_requests/124">Add wake word stripping regression test</a>
              <a class="author_link" href="/chen">Alex Chen</a>
              <span class="ci-status-link ci-status-icon-success" aria-label="Passed"></span>
            </li>
            <li class="merge-request" data-testid="merge-request">
              <a href="https://gitlab.example.test/group/solo/-/merge_requests/9">Title only change</a>
            </li>
          </ul>
        </main>
        </body></html>
        """
    }

    private var emptyListHTML: String {
        """
        <html><body>
        <div class="empty-state"><h4>No merge requests</h4></div>
        </body></html>
        """
    }

    /// Current GitLab renders the Pajamas EmptyState component on list pages
    /// that have no rows yet; it must still read as a valid empty list.
    private var modernEmptyListHTML: String {
        """
        <html><body>
        <div class="gl-empty-state"><h4>No merge requests</h4></div>
        </body></html>
        """
    }

    private var authPageHTML: String {
        """
        <html><body>
        <form id="new_user" action="/users/sign_in">
          <input name="user[login]">
          <input name="user[password]" type="password">
        </form>
        </body></html>
        """
    }

    private var unsupportedPageHTML: String {
        """
        <html><body>
        <h1>Project wiki</h1>
        <p>Some other page entirely.</p>
        </body></html>
        """
    }

    /// A merge-request list container that has rendered but has no rows and no
    /// empty state yet — hydration in progress, never a decisive empty list.
    private var hydratingContainerHTML: String {
        """
        <html><body>
        <ul class="merge_requests-list" id="merge_requests_list"></ul>
        </body></html>
        """
    }

    private var containerWithEmptyStateHTML: String {
        """
        <html><body>
        <ul class="merge_requests-list" id="merge_requests_list"></ul>
        <div class="gl-empty-state"><h4>No merge requests</h4></div>
        </body></html>
        """
    }

    /// A non-list page that merely links one merge request must not be read
    /// as a one-item list.
    private var nonListPageWithMRLinkHTML: String {
        """
        <html><body>
        <h1>Project wiki</h1>
        <p>Related work:
          <a href="https://gitlab.example.test/group/console-ios/-/merge_requests/77">Fix login loop</a>
        </p>
        </body></html>
        """
    }

    private var dashboardWidgetWithMRLinkHTML: String {
        """
        <html><body>
        <div class="dashboard-widget">
          <ul class="widget-list">
            <li><a href="https://gitlab.example.test/group/console-ios/-/merge_requests/31">Widget change</a></li>
          </ul>
        </div>
        </body></html>
        """
    }

    /// Same MR linked twice inside one row plus the same URL repeated in a
    /// second row; must collapse to one card.
    private var duplicateAnchorsHTML: String {
        """
        <html><body>
        <ul id="merge_requests_list">
          <li class="merge-request">
            <a href="https://gitlab.example.test/a/b/-/merge_requests/5">Duplicated change</a>
            <a href="https://gitlab.example.test/a/b/-/merge_requests/5">!5</a>
          </li>
          <li class="merge-request">
            <a href="https://gitlab.example.test/a/b/-/merge_requests/5">Duplicated change again</a>
          </li>
        </ul>
        </body></html>
        """
    }

    /// The same IID in two different projects must stay distinct.
    private var sameIIDTwoProjectsHTML: String {
        """
        <html><body>
        <ul id="merge_requests_list">
          <li class="merge-request">
            <a href="https://gitlab.example.test/alpha/core/-/merge_requests/42">Alpha core change</a>
          </li>
          <li class="merge-request">
            <a href="https://gitlab.example.test/beta/tools/-/merge_requests/42">Beta tools change</a>
          </li>
        </ul>
        </body></html>
        """
    }

    private var draftTitlePrefixHTML: String {
        """
        <html><body>
        <ul id="merge_requests_list">
          <li class="merge-request">
            <a href="https://gitlab.example.test/x/y/-/merge_requests/3">[Draft] Spike streaming parser</a>
          </li>
        </ul>
        </body></html>
        """
    }

    // MARK: - WebPage harness

    private func makePage() -> WebPage {
        CodeHostWebSessionStore.makePage(dataStore: WKWebsiteDataStore.nonPersistent())
    }

    @discardableResult
    private func loadHTML(_ html: String, into page: WebPage, baseURL: URL? = nil) async throws -> Bool {
        let events = page.load(
            html: html,
            baseURL: baseURL ?? URL(string: baseURLString)!
        )
        for try await event in events {
            if case .finished = event { return true }
        }
        return false
    }

    /// Runs the production JavaScript over `html` and decodes the result.
    private func extract(from html: String) async throws -> MergeRequestListExtractionResult {
        let page = makePage()
        _ = try await loadHTML(html, into: page)
        let raw = try await page.callJavaScript(GitLabListExtractorJavaScript.source)
        let json = try XCTUnwrap(raw as? String, "Extractor must return a JSON string")
        return try MergeRequestListExtractor.decode(json)
    }

    // MARK: - Real-JS extraction outcomes

    private var modernPopulatedListHTML: String {
        """
        <html><body>
        <a href="/p/-/merge_requests/99">Unrelated widget</a>
        <div class="issuable-list-container">
          <ul class="content-list issuable-list issues-list">
            <li class="merge-request" data-testid="issuable-container">
              <a href="/p/-/merge_requests/77">Cannot be merged automatically</a>
              <span data-testid="issuable-draft-status-badge">Draft</span>
              <a data-testid="issuable-title-link" class="issue-title-text" href="/p/-/merge_requests/7">Modern review title</a>
            </li>
            <li class="merge-request" style="display:none">
              <a href="/p/-/merge_requests/8">Hidden template</a>
            </li>
            <li class="issue"><a href="/p/-/merge_requests/9">Unrelated issue reference</a></li>
          </ul>
        </div></body></html>
        """
    }

    func testModernListUsesTitleLinkAndOnlyVisibleMRRows() async throws {
        guard case .items(let items) = try await extract(from: modernPopulatedListHTML) else {
            return XCTFail("Expected modern MR list")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.iidText, "7")
        XCTAssertEqual(items.first?.title, "Modern review title")
        XCTAssertEqual(items.first?.isDraft, true)
    }

    func testModernContainerOnIssueOrWidgetRouteIsUnsupported() async throws {
        for route in ["/dashboard/issues", "/dashboard", "/p/-/issues"] {
            let page = makePage()
            _ = try await loadHTML(modernPopulatedListHTML, into: page,
                                   baseURL: URL(string: "https://gitlab.example.test" + route)!)
            let raw = try await page.callJavaScript(GitLabListExtractorJavaScript.source)
            let json = try XCTUnwrap(raw as? String)
            XCTAssertEqual(try MergeRequestListExtractor.decode(json), .unsupportedPage)
            XCTAssertTrue(json.contains("wrongPage"))
        }
    }

    func testModernListHydrationThenRowsOnRetainedPage() async throws {
        let page = makePage()
        _ = try await loadHTML("""
        <html><body><div class="issuable-list-container">
        <ul class="content-list issuable-list issues-list"></ul>
        </div></body></html>
        """, into: page)
        let initial = try await page.callJavaScript(GitLabListExtractorJavaScript.source)
        let initialJSON = try XCTUnwrap(initial as? String)
        XCTAssertEqual(try MergeRequestListExtractor.decode(initialJSON), .unsupportedPage)
        XCTAssertTrue(initialJSON.contains("listNotReady"))
        _ = try await page.callJavaScript("""
        document.querySelector('ul').innerHTML = '<li class="merge-request"><a data-testid="issuable-title-link" href="/p/-/merge_requests/3">Hydrated review</a></li>';
        """)
        let settled = try await page.callJavaScript(GitLabListExtractorJavaScript.source)
        guard case .items(let items) = try MergeRequestListExtractor.decode(XCTUnwrap(settled as? String)) else {
            return XCTFail("Expected hydrated list")
        }
        XCTAssertEqual(items.first?.title, "Hydrated review")
    }

    func testModernEmptyStateIsScopedAwayFromWidgetLinks() async throws {
        let result = try await extract(from: """
        <html><body><a href="/p/-/merge_requests/99">Widget</a>
        <div class="issuable-list-container">
          <div class="gl-empty-state">There are no open merge requests</div>
        </div></body></html>
        """)
        XCTAssertEqual(result, .empty)
    }

    func testModernIssueRowsDoNotBecomeReviewCards() async throws {
        let result = try await extract(from: """
        <html><body><div class="issuable-list-container">
        <ul class="content-list issuable-list issues-list">
          <li class="issue"><a href="/p/-/merge_requests/99">Related MR</a></li>
        </ul></div></body></html>
        """)
        XCTAssertEqual(result, .unsupportedPage)
    }

    func testUnrelatedEmptyPageIsNotAnEmptyReviewList() async throws {
        let page = makePage()
        _ = try await loadHTML(emptyListHTML, into: page, baseURL: URL(string: "https://gitlab.example.test/wiki")!)
        let raw = try await page.callJavaScript(GitLabListExtractorJavaScript.source)
        let json = try XCTUnwrap(raw as? String)
        XCTAssertEqual(try MergeRequestListExtractor.decode(json), .unsupportedPage)
    }

    func testPermissionErrorEmptyComponentIsNotAnEmptyQueue() async throws {
        let result = try await extract(from: "<html><body><div class='empty-state'>You cannot access this project.</div></body></html>")
        XCTAssertEqual(result, .unsupportedPage)
    }

    func testAllMalformedRowsAreNotAnEmptyQueue() throws {
        let result = try MergeRequestListExtractor.decode(#"{"outcome":"items","items":[{"title":"Fixture","url":"not-absolute"}]}"#)
        XCTAssertEqual(result, .unsupportedPage)
    }

    func testHeadlessExtractionIgnoresHiddenTemplatesAndUnrelatedLinks() async throws {
        let html = """
        <html><body>
        <a href="https://gitlab.example.test/p/-/merge_requests/99">Unrelated widget</a>
        <ul id="merge_requests_list">
          <li style="display:none"><a href="https://gitlab.example.test/p/-/merge_requests/1">Hidden template</a></li>
          <li><a href="https://gitlab.example.test/p/-/merge_requests/2">Visible card</a>
            <span class="review-state" style="display:none">Wrong hidden state</span>
            <span class="review-state">Approved</span>
          </li>
        </ul></body></html>
        """
        // This harness deliberately never mounts a WebView, just like Home.
        guard case .items(let items) = try await extract(from: html) else { return XCTFail("Expected cards") }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.iidText, "2")
        XCTAssertEqual(items.first?.reviewDisplayState, "Approved")
    }

    func testItemsAreExtractedWithVisibleFieldsInDOMOrder() async throws {
        guard case .items(let items) = try await extract(from: fullListHTML) else {
            return XCTFail("Expected items outcome")
        }

        XCTAssertEqual(items.count, 4, "Every rendered row should become one card")

        // DOM order preserved.
        XCTAssertEqual(items.map(\.sourceOrder), [0, 1, 2, 3])
        XCTAssertEqual(items[0].iidText, "123")
        XCTAssertEqual(items[1].iidText, "7")
        XCTAssertEqual(items[2].iidText, "124")
        XCTAssertEqual(items[3].iidText, "9")

        // Row 1: full field set.
        XCTAssertEqual(items[0].title, "Fix account recovery navigation crash")
        XCTAssertEqual(items[0].projectDisplayName, "Console iOS")
        XCTAssertEqual(items[0].authorDisplayName, "Alex Chen")
        XCTAssertEqual(items[0].pipelineDisplayState, "Failed")
        XCTAssertEqual(items[0].updatedText, "updated 2h ago")
        XCTAssertEqual(items[0].targetVersionText, "24.10")
        XCTAssertFalse(items[0].isDraft)
        XCTAssertEqual(items[0].id.absoluteString, "https://gitlab.example.test/group/console-ios/-/merge_requests/123")

        // Row 2: draft badge detected without a title prefix.
        XCTAssertTrue(items[1].isDraft)
        XCTAssertNil(items[1].pipelineDisplayState, "Absent pipeline must stay absent")

        // Row 3: pipeline passed present, no updated time rendered.
        XCTAssertEqual(items[2].pipelineDisplayState, "Passed")
        XCTAssertEqual(items[2].authorDisplayName, "Alex Chen")
        XCTAssertNil(items[2].updatedText)

        // Row 4: title-only row still yields a navigable card.
        XCTAssertEqual(items[3].title, "Title only change")
        XCTAssertNil(items[3].projectDisplayName)
        XCTAssertNil(items[3].authorDisplayName)
        XCTAssertNil(items[3].pipelineDisplayState)
        XCTAssertNil(items[3].updatedText)
        XCTAssertNil(items[3].targetVersionText)
        XCTAssertFalse(items[3].isDraft)
    }

    func testEmptyListIsPositivelyIdentified() async throws {
        let result = try await extract(from: emptyListHTML)
        XCTAssertEqual(result, .empty)
    }

    func testModernGitLabEmptyStateIsPositivelyIdentified() async throws {
        let result = try await extract(from: modernEmptyListHTML)
        XCTAssertEqual(result, .empty)
    }

    func testAuthenticationPageIsDetectedBeforeAnythingElse() async throws {
        let result = try await extract(from: authPageHTML)
        XCTAssertEqual(result, .authenticationRequired)
    }

    func testUnsupportedPageIsReportedWhenNothingMatches() async throws {
        let result = try await extract(from: unsupportedPageHTML)
        XCTAssertEqual(result, .unsupportedPage)
    }

    func testHydratingContainerWithoutRowsOrEmptyStateIsNotDecisiveEmpty() async throws {
        let result = try await extract(from: hydratingContainerHTML)
        XCTAssertEqual(result, .unsupportedPage, "A bare container may still be hydrating")
    }

    func testContainerWithPositiveEmptyStateIsStillEmpty() async throws {
        let result = try await extract(from: containerWithEmptyStateHTML)
        XCTAssertEqual(result, .empty)
    }

    func testMRLinkOnNonListPageIsUnsupported() async throws {
        let result = try await extract(from: nonListPageWithMRLinkHTML)
        XCTAssertEqual(result, .unsupportedPage)
    }

    func testDashboardWidgetWithMRLinkIsUnsupported() async throws {
        let result = try await extract(from: dashboardWidgetWithMRLinkHTML)
        XCTAssertEqual(result, .unsupportedPage)
    }

    func testDuplicateAnchorsCollapseToOneCardPreservingOrder() async throws {
        guard case .items(let items) = try await extract(from: duplicateAnchorsHTML) else {
            return XCTFail("Expected items outcome")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.only?.iidText, "5")
        XCTAssertEqual(items.only?.title, "Duplicated change", "First verified row wins")
    }

    func testSameIIDInTwoProjectsStaysDistinct() async throws {
        guard case .items(let items) = try await extract(from: sameIIDTwoProjectsHTML) else {
            return XCTFail("Expected items outcome")
        }
        XCTAssertEqual(items.count, 2, "IID is not identity; URLs are")
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertEqual(items[0].iidText, items[1].iidText)
    }

    func testDraftTitlePrefixIsNormalizedOnce() async throws {
        guard case .items(let items) = try await extract(from: draftTitlePrefixHTML) else {
            return XCTFail("Expected items outcome")
        }
        XCTAssertTrue(items[0].isDraft)
        XCTAssertEqual(items[0].title, "Spike streaming parser", "Draft cue must not repeat inside the title")
    }

    func testFragmentOnlyDifferencesNormalizeToSameIdentity() {
        let first = MergeRequestListExtractor.normalizedMRURL(
            from: "https://gitlab.example.test/g/p/-/merge_requests/11"
        )
        let second = MergeRequestListExtractor.normalizedMRURL(
            from: "https://gitlab.example.test/g/p/-/merge_requests/11#discussion"
        )
        XCTAssertEqual(first, second)
    }

    // MARK: - Swift decode layer

    func testDecodeRejectsInvalidPayload() {
        XCTAssertThrowsError(try MergeRequestListExtractor.decode("not json"))
        XCTAssertThrowsError(try MergeRequestListExtractor.decode("{\"outcome\": 12}"))
    }

    func testDecodeMapsOutcomeStrings() throws {
        XCTAssertEqual(try MergeRequestListExtractor.decode(#"{"outcome":"authenticationRequired","items":[]}"#), .authenticationRequired)
        XCTAssertEqual(try MergeRequestListExtractor.decode(#"{"outcome":"empty","items":[]}"#), .empty)
        XCTAssertEqual(try MergeRequestListExtractor.decode(#"{"outcome":"unsupported","items":[]}"#), .unsupportedPage)
    }

    func testRowsWithoutURLorTitleAreDropped() {
        let rows: [MergeRequestListExtractor.Row] = [
            MergeRequestListExtractor.Row(url: nil, title: "No link row"),
            MergeRequestListExtractor.Row(url: "ftp://gitlab.example.test/p/-/merge_requests/1", title: "Bad scheme"),
            MergeRequestListExtractor.Row(url: "https://gitlab.example.test/p/-/merge_requests/2", title: nil),
            MergeRequestListExtractor.Row(url: "https://gitlab.example.test/p/-/merge_requests/3", iid: "3", title: "Keep me"),
        ]
        let items = MergeRequestListExtractor.summaries(from: rows)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].iidText, "3")
        XCTAssertEqual(items[0].sourceOrder, 0, "Order index is compacted after filtering")
    }

    func testSummariesDeduplicateByNormalizedURLKeepingFirstOccurrence() {
        let rows: [MergeRequestListExtractor.Row] = [
            MergeRequestListExtractor.Row(url: "https://gitlab.example.test/a/-/merge_requests/1#x", iid: "1", title: "First"),
            MergeRequestListExtractor.Row(url: "https://gitlab.example.test/b/-/merge_requests/2", iid: "2", title: "Second"),
            MergeRequestListExtractor.Row(url: "https://gitlab.example.test/a/-/merge_requests/1", iid: "1", title: "Duplicate of first"),
        ]
        let items = MergeRequestListExtractor.summaries(from: rows)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "First")
        XCTAssertEqual(items.map(\.sourceOrder), [0, 1], "GitLab order preserved after dedupe")
    }

    func testOptionalFieldsOmittedWhenMissingNeverUnknown() {
        let rows: [MergeRequestListExtractor.Row] = [
            MergeRequestListExtractor.Row(url: "https://gitlab.example.test/a/-/merge_requests/8", title: "Minimal")
        ]
        let items = MergeRequestListExtractor.summaries(from: rows)
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertNil(item.projectDisplayName)
        XCTAssertNil(item.authorDisplayName)
        XCTAssertNil(item.pipelineDisplayState)
        XCTAssertNil(item.reviewDisplayState)
        XCTAssertNil(item.updatedText)
        XCTAssertNil(item.targetVersionText)
        XCTAssertFalse(item.isDraft)
    }

    // MARK: - Redaction

    func testExtractionResultDescriptionsContainNoExtractedValues() throws {
        let json = """
        {"outcome":"items","items":[{"url":"https://gitlab.example.test/private/widget/-/merge_requests/99","iid":"99","title":"SECRET TITLE VALUE","project":"SECRET PROJECT","author":"SECRET AUTHOR"}]}
        """
        let result = try MergeRequestListExtractor.decode(json)

        for representation in ["\(result)", String(describing: result), String(reflecting: result)] {
            XCTAssertFalse(representation.contains("SECRET"), "Description leaked extracted values: \(representation)")
            XCTAssertFalse(representation.contains("merge_requests"), "Description leaked a URL shape: \(representation)")
        }
    }
}

extension Array where Element == MergeRequestSummary {
    var only: Element? { count == 1 ? first : nil }
}
