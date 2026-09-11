import XCTest
@testable import Console

final class JiraListExtractorTests: XCTestCase {
    private func row(
        key: String?,
        summary: String,
        status: String?,
        priority: String?,
        updated: String?,
        url: String? = nil,
        type: String? = nil
    ) -> JiraListExtractor.ExtractedRow {
        JiraListExtractor.ExtractedRow(
            key: key,
            summary: summary,
            status: status,
            priority: priority,
            updated: updated,
            url: url ?? "https://jira.example.com/browse/\(key ?? "UNKNOWN")",
            type: type
        )
    }

    func testTicketsDecodeWithAllFieldsPreserved() throws {
        let data = Data("""
        {"kind":"tickets","rows":[
          {"key":"DEMO-101","summary":"Fix background refresh after sign-in","status":"In Progress","priority":"High","updated":"Updated 2h","type":"Bug","url":"https://jira.example.com/browse/DEMO-101"}
        ]}
        """.utf8)

        let extraction = JiraListExtractor.decode(payloadData: data)

        guard case let .tickets(tickets) = extraction else {
            return XCTFail("expected tickets, got \(extraction)")
        }
        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets[0].key, "DEMO-101")
        XCTAssertEqual(tickets[0].summary, "Fix background refresh after sign-in")
        XCTAssertEqual(tickets[0].status, "In Progress")
        XCTAssertEqual(tickets[0].priority, "High")
        XCTAssertEqual(tickets[0].updatedText, "Updated 2h")
        XCTAssertEqual(tickets[0].issueType, "Bug")
        XCTAssertEqual(tickets[0].issueURL.absoluteString, "https://jira.example.com/browse/DEMO-101")
        XCTAssertEqual(tickets[0].sourceOrder, 0)
    }

    func testKindStringsMapToDistinctOutcomes() {
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data(#"{"kind":"empty"}"#.utf8)), .empty)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data(#"{"kind":"empty","signedIn":true}"#.utf8)), .empty)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data(#"{"kind":"empty","signedIn":false}"#.utf8)), .authenticationRequired)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data(#"{"kind":"auth"}"#.utf8)), .authenticationRequired)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data(#"{"kind":"unsupported"}"#.utf8)), .unsupportedPage)
    }

    func testMalformedJSONBecomesFailureNeverFalseEmpty() {
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data("not json".utf8)), .failed)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data(#"{"kind":"bogus"}"#.utf8)), .failed)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: Data()), .failed)
    }

    func testSummaryContainingLiteralIssueKeyKeepsOwnKey() {
        let rows = [
            row(key: "SCRUM-13", summary: "Handle the literal text SCRUM-999 correctly", status: "Next Up", priority: "Highest", updated: nil),
            row(key: "SCRUM-999", summary: "Unrelated ticket", status: nil, priority: nil, updated: nil),
        ]

        let tickets = JiraListExtractor.summaries(from: rows)

        XCTAssertEqual(tickets.count, 2)
        XCTAssertEqual(tickets[0].key, "SCRUM-13")
        XCTAssertTrue(tickets[0].summary.contains("SCRUM-999"))
        XCTAssertEqual(tickets[1].key, "SCRUM-999")
    }

    func testDuplicateKeysDedupePreservingFirstDOMPosition() {
        let rows = [
            row(key: "DEMO-2", summary: "second", status: nil, priority: nil, updated: nil),
            row(key: "DEMO-1", summary: "first", status: nil, priority: nil, updated: nil),
            row(key: "DEMO-2", summary: "second again", status: nil, priority: nil, updated: nil),
        ]

        let tickets = JiraListExtractor.summaries(from: rows)

        XCTAssertEqual(tickets.map(\.key), ["DEMO-2", "DEMO-1"])
        XCTAssertEqual(tickets.map(\.sourceOrder), [0, 1])
    }

    func testOptionalFieldsCollapseAndWhitespaceNormalises() {
        let messy = JiraListExtractor.ExtractedRow(
            key: "DEMO-7",
            summary: "  repeated   spaces\tand tabs  ",
            status: "   In   Review ",
            priority: "none",
            updated: "",
            url: "https://jira.example.com/browse/DEMO-7",
            type: " Bug "
        )

        let tickets = JiraListExtractor.summaries(from: [messy])

        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets[0].summary, "repeated spaces and tabs")
        XCTAssertEqual(tickets[0].status, "In Review")
        XCTAssertNil(tickets[0].priority)
        XCTAssertNil(tickets[0].updatedText)
        XCTAssertEqual(tickets[0].issueType, "Bug")
    }

    func testTicketsPayloadWithAllRowsDroppedIsFailureNeverFalseEmpty() {
        // Every row unusable (bad scheme): a data/selector failure, never a
        // legitimate empty list.
        let data = Data(#"{"kind":"tickets","rows":[{"key":"DEMO-1","summary":"bad url","url":"javascript:void(0)"}]}"#.utf8)
        XCTAssertEqual(JiraListExtractor.decode(payloadData: data), .failed)
    }

    func testTicketsPayloadKeepsValidRowsWhenOthersDrop() {
        let data = Data(#"{"kind":"tickets","rows":[{"key":"DEMO-1","summary":"bad url","url":"javascript:void(0)"},{"key":"DEMO-2","summary":"good","url":"https://jira.example.com/browse/DEMO-2"}]}"#.utf8)
        guard case let .tickets(tickets) = JiraListExtractor.decode(payloadData: data) else {
            return XCTFail("expected tickets")
        }
        XCTAssertEqual(tickets.map(\.key), ["DEMO-2"])
    }

    func testRowsWithoutUsableIssueURLAreDropped() {
        let rows = [
            row(key: "DEMO-1", summary: "empty url", status: nil, priority: nil, updated: nil, url: ""),
            row(key: "DEMO-2", summary: "bad scheme", status: nil, priority: nil, updated: nil, url: "javascript:void(0)"),
            row(key: nil, summary: "missing key", status: nil, priority: nil, updated: nil),
            row(key: "DEMO-3", summary: "valid", status: nil, priority: nil, updated: nil),
        ]

        let tickets = JiraListExtractor.summaries(from: rows)

        XCTAssertEqual(tickets.map(\.key), ["DEMO-3"])
        XCTAssertNotNil(tickets.first?.issueURL.host)
    }
}
