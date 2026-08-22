import XCTest
@testable import Console

final class PromptSubmissionTests: XCTestCase {

    // MARK: - Gating

    func testAcceptsOnlyNonemptyPrompts() {
        XCTAssertTrue(PromptSubmissionEngine.acceptsPrompt("hello", activity: .idle))
        XCTAssertTrue(PromptSubmissionEngine.acceptsPrompt("  spaced  ", activity: .idle))
        XCTAssertFalse(PromptSubmissionEngine.acceptsPrompt("", activity: .idle))
        XCTAssertFalse(PromptSubmissionEngine.acceptsPrompt("   ", activity: .idle))
        XCTAssertFalse(PromptSubmissionEngine.acceptsPrompt("\n\t", activity: .idle))
    }

    func testGatesByActivity() {
        for activity in [SessionActivity.starting, .working, .exited, .error, .unknown] {
            XCTAssertFalse(
                PromptSubmissionEngine.acceptsPrompt("hello", activity: activity),
                "\(activity) must not accept prompts"
            )
        }
        XCTAssertTrue(PromptSubmissionEngine.acceptsPrompt("hello", activity: .idle))
    }

    // MARK: - Bracketed paste bytes

    func testSingleLineSendsPlainBytesPlusReturn() {
        let bytes = PromptSubmissionEngine.bytes(for: "hi")
        XCTAssertEqual(bytes, Array("hi".utf8) + PromptSubmissionEngine.returnBytes)
    }

    func testMultilineWrapsInBracketedPaste() {
        let prompt = "line one\nline two"
        let bytes = PromptSubmissionEngine.bytes(for: prompt)

        XCTAssertEqual(Array(bytes.prefix(6)), PromptSubmissionEngine.bracketedPasteStart)
        XCTAssertEqual(Array(bytes.suffix(7)), PromptSubmissionEngine.bracketedPasteEnd + PromptSubmissionEngine.returnBytes)
        XCTAssertTrue(bytes.elementsEqual(
            PromptSubmissionEngine.bracketedPasteStart
                + Array(prompt.utf8)
                + PromptSubmissionEngine.bracketedPasteEnd
                + PromptSubmissionEngine.returnBytes
        ))
    }

    func testBracketedPasteByteValues() {
        // ESC [ 2 0 0 ~
        XCTAssertEqual(PromptSubmissionEngine.bracketedPasteStart, [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        // ESC [ 2 0 1 ~
        XCTAssertEqual(PromptSubmissionEngine.bracketedPasteEnd, [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        // CR
        XCTAssertEqual(PromptSubmissionEngine.returnBytes, [0x0D])
    }
}
