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

    // MARK: - Slash command bytes

    func testSlashCommandBytesArePlainTextPlusCarriageReturn() {
        let bytes = PromptSubmissionEngine.slashCommandBytes("/color purple")
        XCTAssertEqual(bytes, Array("/color purple".utf8) + [0x0D])
    }

    func testSlashCommandBytesForColorReset() {
        XCTAssertEqual(
            PromptSubmissionEngine.slashCommandBytes("/color default"),
            Array("/color default".utf8) + PromptSubmissionEngine.returnBytes
        )
    }

    // MARK: - Replacement command bytes (header menus)

    func testClearDraftBytesAreCtrlUThenCtrlK() {
        // 0x15 = Ctrl+U (kill before cursor), 0x0B = Ctrl+K (kill to end).
        XCTAssertEqual(PromptSubmissionEngine.clearDraftBytes, [0x15, 0x0B])
    }

    func testReplacementCommandBytesOrderClearThenInsertThenReturn() {
        let bytes = PromptSubmissionEngine.replacementCommandBytes("/review-mr")
        XCTAssertEqual(
            bytes,
            PromptSubmissionEngine.clearDraftBytes
                + Array("/review-mr".utf8)
                + PromptSubmissionEngine.returnBytes
        )
        // The draft must be cleared before any command bytes are sent, and
        // Return must come last so insertion and submission stay ordered.
        XCTAssertEqual(Array(bytes.prefix(PromptSubmissionEngine.clearDraftBytes.count)),
                       PromptSubmissionEngine.clearDraftBytes)
        XCTAssertEqual(bytes.last, 0x0D)
    }

    func testReplacementCommandBytesForColorCommand() {
        XCTAssertEqual(
            PromptSubmissionEngine.replacementCommandBytes("/color purple"),
            [0x15, 0x0B] + Array("/color purple".utf8) + [0x0D]
        )
    }

    // MARK: - Session color palette

    func testSessionColorPaletteMatchesClaudeCodeArguments() {
        XCTAssertEqual(
            SessionColorOption.all.map(\.argument),
            ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan", "default"],
            "arguments must match Claude Code's /color command values"
        )
        XCTAssertEqual(
            SessionColorOption.all.map(\.name),
            ["Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Pink", "Cyan", "Default"]
        )
        XCTAssertEqual(SessionColorOption.all.count, Set(SessionColorOption.all.map(\.id)).count)
    }
}
