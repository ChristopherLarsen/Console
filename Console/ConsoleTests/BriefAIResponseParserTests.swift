import XCTest
@testable import Console

final class BriefAIResponseParserTests: XCTestCase {

    func testParseCanonicalResponse() {
        let response = """
        Y1 | Merged attention badge feature
        Y2 | Fixed bridge socket flake
        Y3 | Reviewed MR !12
        T1 | Ship morning brief
        T2 | Write release notes
        """

        let parsed = BriefAIResponseParser.parse(response)

        XCTAssertEqual(
            parsed,
            BriefAIResponseParser.Parsed(
                yesterdayLines: ["Merged attention badge feature", "Fixed bridge socket flake", "Reviewed MR !12"],
                todayTasks: ["Ship morning brief", "Write release notes"]
            )
        )
    }

    func testParseToleratesFencesProseAndBullets() {
        let response = """
        Here is your report:
        ```
        Y1 | - Merged the feature
        y2: skipped tag
        T1 | * Polish the brief
        Some closing remark.
        ```
        """

        let parsed = BriefAIResponseParser.parse(response)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.yesterdayLines, ["Merged the feature"])
        XCTAssertEqual(parsed?.todayTasks, ["Polish the brief"])
    }

    func testParseClampsExtraLinesToReportLimits() {
        let response = """
        Y1 | One
        Y2 | Two
        Y3 | Three
        Y4 | Four
        T1 | Task one
        T2 | Task two
        T3 | Task three
        """

        let parsed = BriefAIResponseParser.parse(response)

        XCTAssertEqual(parsed?.yesterdayLines.count, MorningBrief.maxYesterdayLines)
        XCTAssertEqual(parsed?.todayTasks.count, MorningBrief.maxTodayTasks)
        XCTAssertEqual(parsed?.yesterdayLines.last, "Three")
        XCTAssertEqual(parsed?.todayTasks.last, "Task two")
    }

    func testParseReturnsNilWithoutYesterdayContent() throws {
        XCTAssertNil(BriefAIResponseParser.parse(""))
        XCTAssertNil(BriefAIResponseParser.parse("Just some prose."))
        XCTAssertNil(BriefAIResponseParser.parse("T1 | Only a task"))
    }

    func testCleanStripsWrappingQuotesAndTruncates() {
        let cleaned = BriefAIResponseParser.clean("\"Quoted line\"")
        XCTAssertEqual(cleaned, "Quoted line")

        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(BriefAIResponseParser.clean(long).count, BriefComposer.maxLineLength)
    }

    // MARK: - H38-F02: only numbered Y*/T* slot tags are slots

    func testProseWithPipeIsNotIngestedAsTasks() {
        let parsed = BriefAIResponseParser.parse("""
        Team follow-up | ping bob about the MR
        Today: standup | 10am
        """)
        XCTAssertNil(parsed, "prose with pipes must not become tasks")
    }

    func testProseWithPipeIsIgnoredAroundValidSlots() {
        let parsed = BriefAIResponseParser.parse("""
        Y1 | Merged the feature
        Team follow-up | ping bob about the MR
        T1 | Polish the brief
        """)

        XCTAssertEqual(parsed?.yesterdayLines, ["Merged the feature"])
        XCTAssertEqual(parsed?.todayTasks, ["Polish the brief"])
    }

    func testUnnumberedSlotTagsAreRejected() {
        XCTAssertNil(BriefAIResponseParser.parse("Y | Unnumbered line"))
        XCTAssertNil(BriefAIResponseParser.parse("T | Unnumbered task"))
        XCTAssertNil(BriefAIResponseParser.parse("Yesterday | worked hard"))
    }

    func testSlotTagPredicate() {
        XCTAssertTrue(BriefAIResponseParser.isSlotTag("Y1"))
        XCTAssertTrue(BriefAIResponseParser.isSlotTag("T12"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("Y"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("TEAM FOLLOW-UP"))
        XCTAssertFalse(BriefAIResponseParser.isSlotTag("Y1A"))
    }
}
