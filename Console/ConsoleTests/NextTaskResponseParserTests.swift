import XCTest
@testable import Console

final class NextTaskResponseParserTests: XCTestCase {

    private let validJSON = """
    {
      "task": "review_mr",
      "headline": "Review !88 in AntivirusGodot",
      "lines": ["Fix placement logic", "pipeline failed"],
      "target_url": "https://gitlab.example.com/a/b/-/merge_requests/88",
      "session_name": null
    }
    """

    // MARK: - Happy paths

    func testParseValidReviewTask() {
        let task = NextTaskResponseParser.parse(validJSON)

        XCTAssertNotNil(task)
        XCTAssertEqual(task?.kind, .reviewMergeRequest)
        XCTAssertEqual(task?.headline, "Review !88 in AntivirusGodot")
        XCTAssertEqual(task?.lines.count, 2)
        XCTAssertEqual(
            task?.targetURL,
            URL(string: "https://gitlab.example.com/a/b/-/merge_requests/88")
        )
        XCTAssertNil(task?.sessionName)
    }

    func testParseToleratesMarkdownFencesAndProse() {
        let wrapped = """
        ```json
        \(validJSON)
        ```
        Hope this helps!
        """
        XCTAssertEqual(NextTaskResponseParser.parse(wrapped), NextTaskResponseParser.parse(validJSON))
    }

    func testParseSessionAttentionRequiresSessionName() {
        let good = """
        {"task":"session_attention","headline":"Needs Approval: Antivirus",
         "lines":["Asking to run git push"],"target_url":null,"session_name":"Antivirus"}
        """
        let bad = """
        {"task":"session_attention","headline":"Needs Approval: Antivirus",
         "lines":["Asking to run git push"],"target_url":null,"session_name":""}
        """
        XCTAssertEqual(NextTaskResponseParser.parse(good)?.sessionName, "Antivirus")
        XCTAssertNil(NextTaskResponseParser.parse(bad))
    }

    func testParseNewTicketIgnoresOptionalFields() {
        let json = """
        {"task":"new_ticket","headline":"Start PROJ-412","lines":["Implement the thing"],
         "target_url":"https://jira.example.com/browse/PROJ-412","session_name":null}
        """
        let task = NextTaskResponseParser.parse(json)
        XCTAssertEqual(task?.kind, .newTicket)
        XCTAssertNil(task?.targetURL)
        XCTAssertNil(task?.sessionName)
    }

    // MARK: - Strictness

    func testUnknownTaskValueFails() {
        let json = """
        {"task":"do_a_backflip","headline":"x","lines":["y"]}
        """
        XCTAssertNil(NextTaskResponseParser.parse(json))
    }

    func testEmptyHeadlineFails() {
        let json = """
        {"task":"new_ticket","headline":"   ","lines":["y"]}
        """
        XCTAssertNil(NextTaskResponseParser.parse(json))
    }

    func testMissingURLFailsForMRTasks() {
        let json = """
        {"task":"address_comments","headline":"Address feedback on !12",
         "lines":["Changes requested"],"target_url":null,"session_name":null}
        """
        XCTAssertNil(NextTaskResponseParser.parse(json))

        let nonHTTP = """
        {"task":"address_comments","headline":"Address feedback on !12",
         "lines":["Changes requested"],"target_url":"ftp://nope","session_name":null}
        """
        XCTAssertNil(NextTaskResponseParser.parse(nonHTTP))
    }

    func testMoreThanThreeLinesFailsRatherThanSilentlyDropping() {
        let json = """
        {"task":"new_ticket","headline":"h","lines":["1","2","3","4"]}
        """
        XCTAssertNil(NextTaskResponseParser.parse(json))
    }

    func testNonJSONGarbageFails() {
        XCTAssertNil(NextTaskResponseParser.parse("I could not decide, sorry."))
        XCTAssertNil(NextTaskResponseParser.parse(""))
    }

    // MARK: - Cleaning

    func testCleanCollapsesWhitespaceAndClamps() {
        XCTAssertEqual(
            NextTaskResponseParser.clean("  a \n b  ", maxLength: 10),
            "a b"
        )
        let long = String(repeating: "x", count: 100)
        let cleaned = NextTaskResponseParser.clean(long, maxLength: 20)
        XCTAssertEqual(cleaned.count, 20)
        XCTAssertTrue(cleaned.hasSuffix("…"))
    }

    func testJSONDataFindsObjectInsideProse() {
        let data = NextTaskResponseParser.jsonData(in: "Sure! {\"a\": \"b { \\\"nested\\\" }\"} done")
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), #"{"a": "b { \"nested\" }"}"#)
    }
}
