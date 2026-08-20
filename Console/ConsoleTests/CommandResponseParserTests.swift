import XCTest
@testable import Console

@MainActor
final class CommandResponseParserTests: XCTestCase {

    // MARK: - shortSummary Parsing

    func testParsesShortSummaryFromJSON() throws {
        let json = makeJSON(shortSummary: "Opens Safari browser")
        let command = try CommandResponseParser.parse(json)
        XCTAssertEqual(command.shortSummary, "Opens Safari browser")
    }

    func testTruncatesLongShortSummary() throws {
        let long = String(repeating: "A", count: 80)
        let json = makeJSON(shortSummary: long)
        let command = try CommandResponseParser.parse(json)
        XCTAssertLessThanOrEqual(command.shortSummary.count, 60)
        XCTAssertTrue(command.shortSummary.hasSuffix("..."))
    }

    func testFallsBackToNameWhenSummaryMissing() throws {
        let json = makeJSON(shortSummary: nil)
        let command = try CommandResponseParser.parse(json)
        XCTAssertEqual(command.shortSummary, "test_command")
    }

    func testFallsBackToNameWhenSummaryAndTriggersEmpty() throws {
        let json = """
        {
          "name": "test_command",
          "actions": []
        }
        """
        let command = try CommandResponseParser.parse(json)
        XCTAssertEqual(command.shortSummary, "test_command")
    }

    // MARK: - actionDescription Parsing

    func testParsesActionDescriptionFromJSON() throws {
        let desc = "This command will:\\n• Open Safari"
        let json = makeJSON(actionDescription: desc)
        let command = try CommandResponseParser.parse(json)
        XCTAssertTrue(command.actionDescription.contains("This command will:"))
    }

    func testAddsHeaderWhenMissing() throws {
        let desc = "• Step one\\n• Step two"
        let json = makeJSON(actionDescription: desc)
        let command = try CommandResponseParser.parse(json)
        XCTAssertTrue(command.actionDescription.hasPrefix("This command will:"))
        XCTAssertTrue(command.actionDescription.contains("•"))
    }

    func testFallsBackToActionsArrayWhenDescriptionMissing() throws {
        let json = makeJSON(actionDescription: nil)
        let command = try CommandResponseParser.parse(json)
        XCTAssertTrue(command.actionDescription.contains("This command will:"))
        XCTAssertTrue(command.actionDescription.contains("•"))
    }

    func testEmptyActionsProducesEmptyDescription() throws {
        let json = """
        {
          "name": "empty_cmd",
          "actions": []
        }
        """
        let command = try CommandResponseParser.parse(json)
        XCTAssertTrue(command.actionDescription.isEmpty)
    }

    // MARK: - Helpers

    private func makeJSON(
        shortSummary: String? = "Opens test app",
        actionDescription: String? = "This command will:\\n• Do something"
    ) -> String {
        var fields = """
        "name": "test_command",
        "actions": [
          { "type": "shell", "payload": "open -a Test", "order": 0 }
        ]
        """
        if let s = shortSummary {
            fields += ",\n\"shortSummary\": \"\(s)\""
        }
        if let d = actionDescription {
            fields += ",\n\"actionDescription\": \"\(d)\""
        }
        return "{\n\(fields)\n}"
    }
}
