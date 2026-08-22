import XCTest
import WebKit
@testable import Console

/// Extraction against hand-written synthetic GitHub-like HTML. No live GitHub
/// login is involved anywhere; every URL, repository, title, and name below is
/// invented fixture data.
///
/// The real JavaScript extractor runs inside a nonpersistent `WebPage`, exactly
/// as production does over an authenticated github.com page.
@MainActor
final class GitHubPullRequestListExtractorTests: XCTestCase {

    // MARK: - Synthetic fixtures (invented data)

    private let baseURLString = "https://github.example.test/"

    private var fullListHTML: String {
        """
        <html><body>
        <main>
          <ul id="js-navigation-container">
            <li class="js-issue-row Box-row">
              <a data-hovercard-type="repository" href="/acme/console-ios">acme/console-ios</a>
              <a href="https://github.example.test/acme/console-ios/pull/123">#123</a>
              <a href="https://github.example.test/acme/console-ios/pull/123" class="markdown-title">Fix account recovery navigation crash</a>
              <span class="opened-by"><a data-hovercard-type="user" href="/chen">Alex Chen</a> opened 3 days ago</span>
              <span aria-label="Checks failed" class="octicon octicon-x"></span>
              <relative-time datetime="2026-08-22T10:00:00Z">updated 2h ago</relative-time>
            </li>
            <li class="js-issue-row Box-row">
              <a data-hovercard-type="repository" href="/acme/console-ios">acme/console-ios</a>
              <span class="Label Label--draft">Draft</span>
              <a href="https://github.example.test/acme/console-ios/pull/7">#7</a>
              <a href="https://github.example.test/acme/console-ios/pull/7" class="markdown-title">Rework resize handle gestures</a>
              <span class="opened-by"><a data-hovercard-type="user" href="/sam">Sam Ortiz</a> opened last week</span>
              <relative-time datetime="2026-08-21T09:00:00Z">updated 1d ago</relative-time>
            </li>
            <li class="js-issue-row Box-row">
              <a data-hovercard-type="repository" href="/acme/terminal-bridge">acme/terminal-bridge</a>
              <a href="https://github.example.test/acme/terminal-bridge/pull/124">Add wake word stripping regression test</a>
              <span class="opened-by"><a data-hovercard-type="user" href="/chen">Alex Chen</a> opened yesterday</span>
              <span aria-label="Checks passing" class="octicon octicon-check"></span>
            </li>
            <li class="js-issue-row Box-row">
              <a href="https://github.example.test/acme/solo/pull/9">Title only change</a>
            </li>
          </ul>
        </main>
        </body></html>
        """
    }

    private var emptyListHTML: String {
        """
        <html><body>
        <div class="blankslate"><h3>No results matched your search.</h3></div>
        </body></html>
        """
    }

    private var authPageHTML: String {
        """
        <html><body>
        <form action="/session">
          <input name="login">
          <input name="password" type="password">
        </form>
        </body></html>
        """
    }

    private var unsupportedPageHTML: String {
        """
        <html><body>
        <h1>Repository wiki</h1>
        <p>Some other page entirely.</p>
        </body></html>
        """
    }

    /// Same PR linked twice inside one row plus the same URL repeated in a
    /// second row; must collapse to one card.
    private var duplicateAnchorsHTML: String {
        """
        <html><body>
        <ul>
          <li class="js-issue-row">
            <a href="https://github.example.test/a/b/pull/5">Duplicated change</a>
            <a href="https://github.example.test/a/b/pull/5">#5</a>
          </li>
          <li class="js-issue-row">
            <a href="https://github.example.test/a/b/pull/5">Duplicated change again</a>
          </li>
        </ul>
        </body></html>
        """
    }

    /// The same PR number in two different repositories must stay distinct.
    private var sameNumberTwoReposHTML: String {
        """
        <html><body>
        <ul>
          <li class="js-issue-row">
            <a href="https://github.example.test/alpha/core/pull/42">Alpha core change</a>
          </li>
          <li class="js-issue-row">
            <a href="https://github.example.test/beta/tools/pull/42">Beta tools change</a>
          </li>
        </ul>
        </body></html>
        """
    }

    /// A non-pull-request link shape must never be picked up as a row.
    private var issueLinksOnlyHTML: String {
        """
        <html><body>
        <ul>
          <li class="js-issue-row">
            <a href="https://github.example.test/a/b/issues/11">An issue, not a pull request</a>
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
    private func loadHTML(_ html: String, into page: WebPage) async throws -> Bool {
        let events = page.load(
            html: html,
            baseURL: URL(string: baseURLString)!
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
        let raw = try await page.callJavaScript(GitHubListExtractorJavaScript.source)
        let json = try XCTUnwrap(raw as? String, "Extractor must return a JSON string")
        return try MergeRequestListExtractor.decode(json)
    }

    // MARK: - Real-JS extraction outcomes

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
        XCTAssertEqual(items[0].projectDisplayName, "acme/console-ios")
        XCTAssertEqual(items[0].authorDisplayName, "Alex Chen")
        XCTAssertEqual(items[0].pipelineDisplayState, "Failed")
        XCTAssertEqual(items[0].updatedText, "updated 2h ago")
        XCTAssertFalse(items[0].isDraft)
        XCTAssertEqual(
            items[0].id.absoluteString,
            "https://github.example.test/acme/console-ios/pull/123"
        )

        // Row 2: Draft badge detected without a title prefix.
        XCTAssertTrue(items[1].isDraft)
        XCTAssertNil(items[1].pipelineDisplayState, "Absent pipeline must stay absent")

        // Row 3: passing checks present, no updated time rendered.
        XCTAssertEqual(items[2].pipelineDisplayState, "Passed")
        XCTAssertEqual(items[2].projectDisplayName, "acme/terminal-bridge")
        XCTAssertNil(items[2].updatedText)

        // Row 4: title-only row still yields a navigable card.
        XCTAssertEqual(items[3].title, "Title only change")
        XCTAssertNil(items[3].projectDisplayName)
        XCTAssertNil(items[3].authorDisplayName)
        XCTAssertNil(items[3].pipelineDisplayState)
        XCTAssertNil(items[3].updatedText)
        XCTAssertFalse(items[3].isDraft)
    }

    func testEmptyListIsPositivelyIdentified() async throws {
        let result = try await extract(from: emptyListHTML)
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

    func testIssueLinksAreNotMistakenForPullRequests() async throws {
        let result = try await extract(from: issueLinksOnlyHTML)
        XCTAssertEqual(result, .unsupportedPage, "Issue pages must not produce cards or a false zero")
    }

    func testDuplicateAnchorsCollapseToOneCardPreservingOrder() async throws {
        guard case .items(let items) = try await extract(from: duplicateAnchorsHTML) else {
            return XCTFail("Expected items outcome")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.only?.iidText, "5")
        XCTAssertEqual(items.only?.title, "Duplicated change", "First verified row wins")
    }

    func testSamePRNumberInTwoReposStaysDistinct() async throws {
        guard case .items(let items) = try await extract(from: sameNumberTwoReposHTML) else {
            return XCTFail("Expected items outcome")
        }
        XCTAssertEqual(items.count, 2, "The number alone is not identity; URLs are")
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertEqual(items[0].iidText, items[1].iidText)
    }
}
