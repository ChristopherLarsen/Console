import XCTest
@testable import Console

@MainActor
final class CommandGeneratorTests: XCTestCase {

    // MARK: - shortSummary Validation

    func testValidateShortSummaryPassesValid() {
        let result = CommandGeneratorPrompt.validateShortSummary("Opens Safari browser")
        XCTAssertEqual(result, "Opens Safari browser")
    }

    func testValidateShortSummaryTruncatesLong() {
        let long = String(repeating: "A", count: 80)
        let result = CommandGeneratorPrompt.validateShortSummary(long)
        XCTAssertLessThanOrEqual(result.count, 60)
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testValidateShortSummaryReturnsEmptyForEmpty() {
        let result = CommandGeneratorPrompt.validateShortSummary("")
        XCTAssertEqual(result, "")
    }

    func testValidateShortSummaryTrimsWhitespace() {
        let result = CommandGeneratorPrompt.validateShortSummary("  Hello  ")
        XCTAssertEqual(result, "Hello")
    }

    func testValidateShortSummaryExactly60Chars() {
        let exact = String(repeating: "B", count: 60)
        let result = CommandGeneratorPrompt.validateShortSummary(exact)
        XCTAssertEqual(result.count, 60)
        XCTAssertFalse(result.hasSuffix("..."))
    }

    func testMaxSummaryLengthIs60() {
        XCTAssertEqual(CommandGeneratorPrompt.maxSummaryLength, 60)
    }

    // MARK: - actionDescription Validation

    func testValidateActionDescriptionPassesValid() {
        let input = "This command will:\n• Open Safari\n• Navigate to Google"
        let result = CommandGeneratorPrompt.validateActionDescription(input)
        XCTAssertTrue(result.hasPrefix("This command will:"))
        XCTAssertTrue(result.contains("•"))
    }

    func testValidateActionDescriptionAddsHeader() {
        let input = "• Step one\n• Step two"
        let result = CommandGeneratorPrompt.validateActionDescription(input)
        XCTAssertTrue(result.hasPrefix("This command will:"))
        XCTAssertTrue(result.contains("• Step one"))
    }

    func testValidateActionDescriptionAddsBullets() {
        let input = "This command will:\nOpen Safari\nGo to Google"
        let result = CommandGeneratorPrompt.validateActionDescription(input)
        XCTAssertTrue(result.contains("•"))
    }

    func testValidateActionDescriptionReturnsEmptyForEmpty() {
        let result = CommandGeneratorPrompt.validateActionDescription("")
        XCTAssertEqual(result, "")
    }

    func testValidateActionDescriptionKeepsSameLineBodyAfterHeader() {
        let input = "This command will: Launch Terminal.app"
        let result = CommandGeneratorPrompt.validateActionDescription(input)
        XCTAssertTrue(result.hasPrefix("This command will:"))
        XCTAssertTrue(result.contains("• Launch Terminal.app"), "same-line body must survive as a bullet, got: \(result)")
    }

    func testValidateActionDescriptionKeepsHeaderlessMultilineBody() {
        let input = "Open Safari\nNavigate to Google"
        let result = CommandGeneratorPrompt.validateActionDescription(input)
        XCTAssertTrue(result.contains("• Open Safari"))
        XCTAssertTrue(result.contains("• Navigate to Google"))
    }

    func testValidateActionDescriptionTrimsWhitespace() {
        let input = "  This command will:\n• Do something  "
        let result = CommandGeneratorPrompt.validateActionDescription(input)
        XCTAssertTrue(result.hasPrefix("This command will:"))
    }

    // MARK: - Fallback Generation

    func testParserFallbackSummaryWithLegacyTriggerPhrases() throws {
        // Backward compat: LLM may still return trigger_phrases from older prompts
        let json = """
        {
          "name": "test",
          "trigger_phrases": ["open the terminal app"],
          "actions": []
        }
        """
        let command = try CommandResponseParser.parse(json)
        XCTAssertEqual(command.shortSummary, "open the terminal app")
    }

    func testParserFallbackSummaryFromName() throws {
        let json = """
        {
          "name": "open_terminal",
          "actions": []
        }
        """
        let command = try CommandResponseParser.parse(json)
        XCTAssertEqual(command.shortSummary, "open_terminal")
    }

    func testParserFallbackActionDescriptionFromActions() throws {
        let json = """
        {
          "name": "test",
          "actions": [
            { "type": "shell", "payload": "open -a Safari", "order": 0 }
          ]
        }
        """
        let command = try CommandResponseParser.parse(json)
        XCTAssertTrue(command.actionDescription.contains("This command will:"))
        XCTAssertTrue(command.actionDescription.contains("•"))
    }

    func testParserPreservesProvidedFields() throws {
        let json = """
        {
          "name": "test",
          "shortSummary": "My custom summary",
          "actionDescription": "This command will:\\n• Custom action",
          "actions": [
            { "type": "shell", "payload": "echo hi", "order": 0 }
          ]
        }
        """
        let command = try CommandResponseParser.parse(json)
        XCTAssertEqual(command.shortSummary, "My custom summary")
        XCTAssertTrue(command.actionDescription.contains("Custom action"))
    }
}
