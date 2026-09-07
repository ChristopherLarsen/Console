import XCTest
import WebKit
@testable import Console

@MainActor
final class JiraWebExtractionIntegrationTests: XCTestCase {
    private func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        return WebPage(configuration: configuration)
    }

    private func waitForDocumentReady(_ page: WebPage, marker: String, timeout: TimeInterval = 15) async -> Bool {
        let script = "return document.readyState === 'complete' && \(marker)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? await page.callJavaScript(script), let satisfied = raw as? Bool, satisfied {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func htmlMarker(_ html: String) -> String {
        if html.contains("issue-navigator-container") {
            return "!!document.querySelector('[data-testid=\"issue-navigator-container\"]')"
        }
        if html.contains("type=\"password\"") {
            return "!!document.querySelector('input[type=password]')"
        }
        if html.contains("page-layout.root") {
            return "!!document.querySelector('[data-testid=\"page-layout.root\"]')"
        }
        return "true"
    }

    private func waitForRows(_ page: WebPage, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? await page.callJavaScript(
                "return document.querySelectorAll('[data-testid=\"native-issue-table.ui.issue-row\"]').length"
            ), let count = raw as? Int, count > 0 {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func loadFixture(_ html: String) async throws -> WebPage {
        let page = makePage()
        page.load(html: html, baseURL: URL(string: "https://jira.example.com/issues/")!)
        let ready = await waitForDocumentReady(page, marker: htmlMarker(html))
        XCTAssertTrue(ready, "fixture document never became ready")
        return page
    }

    func testFullFixtureListExtractsInSourceOrder() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.listHTML())
        _ = await waitForRows(page)

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets, got \(extraction)")
        }
        XCTAssertEqual(tickets.map(\.key), JiraSyntheticFixtures.expectedOrder)
        XCTAssertEqual(tickets.map(\.sourceOrder), Array(tickets.indices))
    }

    func testMarkupSummaryRendersAsLiteralTextNotInterpretedHTML() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.listHTML())
        _ = await waitForRows(page)

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets")
        }
        let markupTicket = tickets.first { $0.key == "SCRUM-7" }
        XCTAssertNotNil(markupTicket)
        XCTAssertTrue(markupTicket?.summary.contains("<b>") ?? false)
        XCTAssertTrue(markupTicket?.summary.contains("&") ?? false)
        XCTAssertTrue(markupTicket?.summary.contains("<script>alert(1)</script>") ?? false)
        XCTAssertFalse(markupTicket?.summary.contains("&lt;") ?? true)
        XCTAssertFalse(markupTicket?.summary.contains("&amp;") ?? true)
    }

    func testSummaryWithLiteralIssueKeyResolvesToOwnKey() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.listHTML())
        _ = await waitForRows(page)

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets")
        }
        let keyInSummary = tickets.first { $0.summary.contains("SCRUM-999") }
        XCTAssertEqual(keyInSummary?.key, "SCRUM-13")
        XCTAssertFalse(tickets.contains { $0.key == "SCRUM-999" })
    }

    func testReorderedColumnsStillMapStatusPriorityAndUpdated() async throws {
        let reordered: [String] = ["", "Work", "Status", "Updated", "Priority", "Created"]
        let page = try await loadFixture(JiraSyntheticFixtures.listHTML(columns: reordered))
        _ = await waitForRows(page)

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets")
        }
        for ticket in tickets {
            let fixture = JiraSyntheticFixtures.fixtures.first { $0.key == ticket.key }
            XCTAssertEqual(ticket.status, fixture?.status, "status mismatch for \(ticket.key)")
            XCTAssertEqual(ticket.priority, fixture?.priority, "priority mismatch for \(ticket.key)")
            XCTAssertEqual(ticket.updatedText, fixture?.updated, "updated mismatch for \(ticket.key)")
        }
    }

    func testMissingOptionalColumnsCollapseCleanly() async throws {
        let minimal: [String] = ["", "Work"]
        let page = try await loadFixture(JiraSyntheticFixtures.listHTML(columns: minimal))

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets")
        }
        XCTAssertEqual(tickets.count, JiraSyntheticFixtures.fixtures.count)
        for ticket in tickets {
            XCTAssertNil(ticket.status)
            XCTAssertNil(ticket.priority)
            XCTAssertNil(ticket.updatedText)
            XCTAssertFalse(ticket.summary.isEmpty)
        }
    }

    func testDuplicateIssueAnchorsDeduplicate() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.listHTML(duplicateKeyAnchor: true))
        _ = await waitForRows(page)

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets")
        }
        XCTAssertEqual(tickets.filter { $0.key == "SCRUM-16" }.count, 1)
        XCTAssertEqual(tickets.count, JiraSyntheticFixtures.fixtures.count)
    }

    func testLeadingNonIssueTableDoesNotHideIssueRows() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.listHTMLWithLeadingNonIssueTable())
        _ = await waitForRows(page)

        let extraction = await JiraListExtractor.extract(from: page)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets, got \(extraction)")
        }
        XCTAssertEqual(tickets.map(\.key), JiraSyntheticFixtures.expectedOrder)
    }

    func testUnrelatedTableWithoutIssueIdentityIsUnsupportedNeverFalseEmpty() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.unrelatedTablePageHTML())

        let extraction = await JiraListExtractor.extract(from: page)

        XCTAssertEqual(extraction, .unsupportedPage)
    }

    func testEmptyListIsPositivelyIdentified() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.emptyListHTML(signedIn: true))

        let extraction = await JiraListExtractor.extract(from: page)

        XCTAssertEqual(extraction, .empty)
    }

    func testAnonymousZeroResultsIsTreatedAsAuthenticationRequired() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.emptyListHTML(signedIn: false))

        let extraction = await JiraListExtractor.extract(from: page)

        XCTAssertEqual(extraction, .authenticationRequired)
    }

    func testAuthenticationPageIsDetected() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.authenticationHTML())

        let extraction = await JiraListExtractor.extract(from: page)

        XCTAssertEqual(extraction, .authenticationRequired)
    }

    func testNonListPageIsUnsupported() async throws {
        let page = try await loadFixture(JiraSyntheticFixtures.dashboardHTML())

        let extraction = await JiraListExtractor.extract(from: page)

        XCTAssertEqual(extraction, .unsupportedPage)
    }
}
