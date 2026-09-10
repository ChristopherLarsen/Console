import XCTest
@testable import Console

final class BriefAIResponseParserTests: XCTestCase {

    func testParseCanonicalResponse() {
        let response = """
        Y1 | Merged attention badge feature
        Y2 | Fixed bridge socket flake
        Y3 | Reviewed MR !12
        """

        let parsed = BriefAIResponseParser.parse(response)

        XCTAssertEqual(
            parsed,
            BriefAIResponseParser.Parsed(
                yesterdayLines: ["Merged attention badge feature", "Fixed bridge socket flake", "Reviewed MR !12"]
            )
        )
    }

    func testParseToleratesFencesProseAndBullets() {
        let response = """
        Here is your report:
        ```
        Y1 | - Merged the feature
        y2: skipped tag
        Some closing remark.
        ```
        """

        let parsed = BriefAIResponseParser.parse(response)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.yesterdayLines, ["Merged the feature"])
    }

    func testParseClampsExtraLinesToReportLimit() {
        let response = """
        Y1 | One
        Y2 | Two
        Y3 | Three
        Y4 | Four
        Y5 | Five
        """

        let parsed = BriefAIResponseParser.parse(response)

        XCTAssertEqual(parsed?.yesterdayLines.count, MorningBrief.maxYesterdayLines)
        XCTAssertEqual(parsed?.yesterdayLines.last, "Three")
    }

    func testParseReturnsNilWithoutYesterdayContent() throws {
        XCTAssertNil(BriefAIResponseParser.parse(""))
        XCTAssertNil(BriefAIResponseParser.parse("Just some prose."))
        XCTAssertNil(BriefAIResponseParser.parse("T1 | Only a task"))
        XCTAssertNil(BriefAIResponseParser.parse("Y | Unnumbered line"))
    }

    func testCleanStripsWrappingQuotesAndTruncates() {
        let cleaned = BriefAIResponseParser.clean("\"Quoted line\"")
        XCTAssertEqual(cleaned, "Quoted line")

        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(BriefAIResponseParser.clean(long).count, BriefComposer.maxLineLength)
    }

    // MARK: - Only numbered Y slot tags are slots

    func testProseWithPipeIsNotIngestedAsLines() {
        let parsed = BriefAIResponseParser.parse("""
        Team follow-up | ping bob about the MR
        Today: standup | 10am
        """)
        XCTAssertNil(parsed, "prose with pipes must not become report lines")
    }

    func testProseWithPipeIsIgnoredAroundValidSlots() {
        let parsed = BriefAIResponseParser.parse("""
        Y1 | Merged the feature
        Team follow-up | ping bob about the MR
        Y2 | Fixed the flake
        """)

        XCTAssertEqual(parsed?.yesterdayLines, ["Merged the feature", "Fixed the flake"])
    }

    func testUnnumberedSlotTagsAreRejected() {
        XCTAssertNil(BriefAIResponseParser.parse("Y | Unnumbered line"))
        XCTAssertNil(BriefAIResponseParser.parse("Yesterday | worked hard"))
    }

    func testSlotTagPredicate() {
        XCTAssertTrue(BriefAIResponseParser.isSlotTag("Y1"))
        XCTAssertTrue(BriefAIResponseParser.isSlotTag("Y12"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("Y"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("TEAM FOLLOW-UP"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("Y1A"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("T1"))
    }
}
