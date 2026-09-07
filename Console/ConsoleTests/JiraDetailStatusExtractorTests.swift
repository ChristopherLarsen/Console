import XCTest
import WebKit
@testable import Console

@MainActor
final class JiraDetailStatusExtractorTests: XCTestCase {
    private let generation = 7
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - JSON decode

    func testMatchedPayloadDecodesDetailFields() {
        let data = Data(#"""
        {"kind":"matched","issueKey":"demo-42","statusLabel":"  Closed  ","pageURL":"https://jira.example.test/browse/DEMO-42","originHost":"Jira.Example.Test"}
        """#.utf8)

        let extraction = JiraDetailStatusExtractor.decode(
            payloadData: data,
            navigationGeneration: generation,
            observedAt: observedAt
        )

        guard case let .matched(detail) = extraction else {
            return XCTFail("expected matched, got \(extraction)")
        }
        XCTAssertEqual(detail.issueKey, "DEMO-42")
        XCTAssertEqual(detail.statusLabel, "Closed")
        XCTAssertEqual(detail.originHost, "jira.example.test")
        XCTAssertEqual(detail.pageURL.absoluteString, "https://jira.example.test/browse/DEMO-42")
        XCTAssertEqual(detail.navigationGeneration, generation)
        XCTAssertEqual(detail.observedAt, observedAt)
    }

    func testKindStringsMapToDistinctOutcomes() {
        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(
                payloadData: Data(#"{"kind":"auth"}"#.utf8),
                navigationGeneration: 1
            ),
            .authenticationRequired
        )
        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(
                payloadData: Data(#"{"kind":"unsupported"}"#.utf8),
                navigationGeneration: 1
            ),
            .unsupportedPage
        )
        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(
                payloadData: Data(#"{"kind":"failed"}"#.utf8),
                navigationGeneration: 1
            ),
            .extractionFailed
        )
        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(
                payloadData: Data("not json".utf8),
                navigationGeneration: 1
            ),
            .extractionFailed
        )
    }

    func testInvalidIssueKeyShapeBecomesExtractionFailed() {
        let data = Data(#"""
        {"kind":"matched","issueKey":"NOTAKEY","statusLabel":"Closed","pageURL":"https://jira.example.test/browse/NOTAKEY","originHost":"jira.example.test"}
        """#.utf8)

        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(
                payloadData: data,
                navigationGeneration: 1
            ),
            .extractionFailed
        )
    }

    func testMissingStatusOrURLBecomesExtractionFailed() {
        let missingStatus = Data(#"""
        {"kind":"matched","issueKey":"DEMO-1","statusLabel":"","pageURL":"https://jira.example.test/browse/DEMO-1","originHost":"jira.example.test"}
        """#.utf8)
        let badScheme = Data(#"""
        {"kind":"matched","issueKey":"DEMO-1","statusLabel":"Closed","pageURL":"javascript:void(0)","originHost":"jira.example.test"}
        """#.utf8)

        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(payloadData: missingStatus, navigationGeneration: 1),
            .extractionFailed
        )
        XCTAssertEqual(
            JiraDetailStatusExtractor.decode(payloadData: badScheme, navigationGeneration: 1),
            .extractionFailed
        )
    }

    // MARK: - HTML fixtures via WebPage

    func testFixtureMatchedClosed() async throws {
        let page = try await loadFixture(
            "matched-closed.html",
            baseURL: URL(string: "https://jira.example.test/browse/DEMO-99")!
        )

        let extraction = await JiraDetailStatusExtractor.extract(
            from: page,
            navigationGeneration: generation,
            observedAt: observedAt
        )

        guard case let .matched(detail) = extraction else {
            return XCTFail("expected matched closed, got \(extraction)")
        }
        XCTAssertEqual(detail.issueKey, "DEMO-99")
        XCTAssertEqual(detail.statusLabel, "Closed")
        XCTAssertEqual(detail.originHost, "jira.example.test")
        XCTAssertEqual(detail.navigationGeneration, generation)
    }

    func testFixtureMatchedNonClosed() async throws {
        let page = try await loadFixture(
            "matched-in-progress.html",
            baseURL: URL(string: "https://jira.example.test/browse/DEMO-42")!
        )

        let extraction = await JiraDetailStatusExtractor.extract(
            from: page,
            navigationGeneration: generation,
            observedAt: observedAt
        )

        guard case let .matched(detail) = extraction else {
            return XCTFail("expected matched, got \(extraction)")
        }
        XCTAssertEqual(detail.issueKey, "DEMO-42")
        XCTAssertEqual(detail.statusLabel, "In Progress")
    }

    func testFixtureAuthWall() async throws {
        let page = try await loadFixture(
            "auth-wall.html",
            baseURL: URL(string: "https://id.example.test/login")!
        )

        let extraction = await JiraDetailStatusExtractor.extract(
            from: page,
            navigationGeneration: 1
        )

        XCTAssertEqual(extraction, .authenticationRequired)
    }

    func testFixtureUnsupportedDashboard() async throws {
        let page = try await loadFixture(
            "unsupported-dashboard.html",
            baseURL: URL(string: "https://jira.example.test/jira/for-you")!
        )

        let extraction = await JiraDetailStatusExtractor.extract(
            from: page,
            navigationGeneration: 1
        )

        XCTAssertEqual(extraction, .unsupportedPage)
    }

    func testFixtureWrongKeyShape() async throws {
        let page = try await loadFixture(
            "wrong-key-shape.html",
            baseURL: URL(string: "https://jira.example.test/browse/NOTAKEY")!
        )

        let extraction = await JiraDetailStatusExtractor.extract(
            from: page,
            navigationGeneration: 1
        )

        XCTAssertEqual(extraction, .extractionFailed)
    }

    // MARK: - Observation builder + privacy

    func testBuilderComputesObservedAssociationViaProvider() {
        let expected = TicketAssociationToken(digest: Data([0x01, 0x02]))
        let observedDigest = Data([0xAA, 0xBB])
        let detail = TicketJiraMatchedDetail(
            issueKey: "SENSITIVE_TICKET_KEY",
            statusLabel: "SENSITIVE_STATUS",
            originHost: "jira.example.test",
            pageURL: URL(string: "https://jira.example.test/browse/SENSITIVE_TICKET_KEY")!,
            observedAt: observedAt,
            navigationGeneration: generation
        )

        var providerHosts: [String] = []
        var providerKeys: [String] = []
        let observation = TicketJiraObservationBuilder.makeObservation(
            extraction: .matched(detail),
            expectedAssociation: expected,
            associationTokenProvider: { host, key in
                providerHosts.append(host)
                providerKeys.append(key)
                return TicketAssociationToken(digest: observedDigest)
            },
            navigationGeneration: generation,
            isFromVisibleIssuePage: true
        )

        XCTAssertEqual(providerHosts, ["jira.example.test"])
        XCTAssertEqual(providerKeys, ["SENSITIVE_TICKET_KEY"])
        XCTAssertEqual(observation.observedAssociation?.digest, observedDigest)
        XCTAssertEqual(observation.expectedAssociation, expected)

        // Sentinel values must stay memory-only — never land in durable DTOs.
        let dto = TicketWorkflowRecordDTO(
            id: UUID(),
            associationDigest: expected.digest,
            templateID: UUID(),
            templateVersion: 1,
            lifecycle: .active,
            currentStage: .close,
            workCycle: 1,
            steps: [],
            blockers: [],
            associatedSessionIDs: [],
            workspaceID: nil,
            createdAt: observedAt,
            updatedAt: observedAt,
            closedAt: nil,
            transitionHistory: []
        )
        let encoded = try! JSONEncoder().encode(dto)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("SENSITIVE_TICKET_KEY"))
        XCTAssertFalse(json.contains("SENSITIVE_STATUS"))
        XCTAssertFalse(json.contains("SENSITIVE_TITLE"))
        XCTAssertFalse(json.contains("jira.example.test"))
    }

    // MARK: - Helpers

    private func fixtureHTML(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JiraDetail/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        return WebPage(configuration: configuration)
    }

    private func loadFixture(_ name: String, baseURL: URL) async throws -> WebPage {
        let html = try fixtureHTML(name)
        XCTAssertFalse(html.isEmpty, "fixture \(name) was empty")
        let page = makePage()
        page.load(html: html, baseURL: baseURL)
        let ready = await waitForDocumentReady(page, marker: htmlMarker(html))
        XCTAssertTrue(ready, "fixture \(name) never became ready")
        return page
    }

    private func htmlMarker(_ html: String) -> String {
        if html.contains("type=\"password\"") {
            return "!!document.querySelector('input[type=password]')"
        }
        if html.contains("issue.views.issue-base") {
            return "!!document.querySelector('[data-testid*=\"issue.views.issue-base\"]')"
        }
        if html.contains("page-layout.root") {
            return "!!document.querySelector('[data-testid=\"page-layout.root\"]')"
        }
        return "true"
    }

    private func waitForDocumentReady(
        _ page: WebPage,
        marker: String = "true",
        timeout: TimeInterval = 15
    ) async -> Bool {
        let script = "return document.readyState === 'complete' && (\(marker))"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? await page.callJavaScript(script),
               let satisfied = raw as? Bool,
               satisfied {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
