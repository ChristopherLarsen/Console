import XCTest
import SwiftData
@testable import Console

final class ConsoleTests: XCTestCase {

    // MARK: - Streaming

    func testDeltaAccumulation() async {
        let deltas = ["Hello", " ", "world", "!"]
        var accumulated = ""
        for d in deltas { accumulated += d }
        XCTAssertEqual(accumulated, "Hello world!")
    }

    func testCodeBlockParserIncompleteBlockDuringStreaming() {
        let markdown = "Here's code:\n```swift\nfunc foo()"
        let segments = CodeBlockParser.parseSegments(from: markdown)
        XCTAssertEqual(segments.count, 2)
        if case .text(let t) = segments[0] {
            XCTAssertTrue(t.contains("Here's code:"))
        } else { XCTFail("Expected text segment") }
        if case .code(let code, let lang) = segments[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "func foo()")
        } else { XCTFail("Expected code segment") }
    }

    func testCodeBlockParserCompleteBlock() {
        let markdown = "Text\n```swift\nprint(1)\n```\nMore"
        let segments = CodeBlockParser.parseSegments(from: markdown)
        XCTAssertEqual(segments.count, 3)
        if case .code(let code, let lang) = segments[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "print(1)\n")
        } else { XCTFail("Expected code segment") }
    }

    // MARK: - Markdown Rendering

    func testMarkdownRendererBold() {
        let result = MarkdownRenderer.parse("**bold**")
        XCTAssertNotNil(result)
        XCTAssertEqual(String(result!.characters), "bold")
    }

    func testMarkdownRendererItalic() {
        let result = MarkdownRenderer.parse("*italic*")
        XCTAssertNotNil(result)
        XCTAssertEqual(String(result!.characters), "italic")
    }

    func testMarkdownRendererInlineCode() {
        let result = MarkdownRenderer.parse("`code`")
        XCTAssertNotNil(result)
        XCTAssertEqual(String(result!.characters), "code")
    }

    func testMarkdownRendererLink() {
        let result = MarkdownRenderer.parse("[link](https://example.com)")
        XCTAssertNotNil(result)
        XCTAssertEqual(String(result!.characters), "link")
    }

    func testMarkdownRendererHeader() {
        let result = MarkdownRenderer.parseStyled("# Heading")
        XCTAssertNotNil(result)
        XCTAssertEqual(String(result!.characters), "Heading")
    }

    func testMarkdownRendererMixedContent() {
        let md = "Some **bold** and *italic* with `code`."
        let result = MarkdownRenderer.parse(md)
        XCTAssertNotNil(result)
    }

    func testCodeBlockParserMixedTextAndCode() {
        let markdown = "Intro\n```python\nx = 1\n```\nOutro"
        let segments = CodeBlockParser.parseSegments(from: markdown)
        XCTAssertEqual(segments.count, 3)
        if case .text(let t) = segments[0] { XCTAssertTrue(t.contains("Intro")) } else { XCTFail() }
        if case .code(let c, let l) = segments[1] {
            XCTAssertEqual(l, "python")
            XCTAssertTrue(c.contains("x = 1"))
        } else { XCTFail() }
        if case .text(let t) = segments[2] { XCTAssertTrue(t.contains("Outro")) } else { XCTFail() }
    }

    func testCodeBlockParserEmptyBlock() {
        let markdown = "Before\n```\n\n```\nAfter"
        let segments = CodeBlockParser.parseSegments(from: markdown)
        XCTAssertEqual(segments.count, 3)
        if case .code(let code, let lang) = segments[1] {
            XCTAssertNil(lang)
            XCTAssertTrue(code.isEmpty || code == "\n")
        } else { XCTFail("Expected code segment for empty block") }
    }

    func testMarkdownRendererNestedFormatting() {
        let md = "**bold *and* italic**"
        let result = MarkdownRenderer.parse(md)
        XCTAssertNotNil(result)
    }

    func testLargeCodeBlock() {
        let lines = (0..<500).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let markdown = "```swift\n\(lines)\n```"
        let segments = CodeBlockParser.parseSegments(from: markdown)
        XCTAssertEqual(segments.count, 1)
        if case .code(let code, let lang) = segments[0] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code.split(separator: "\n").count, 500)
        } else { XCTFail() }
        let highlighted = SyntaxHighlighter.highlight(code: lines, language: "swift")
        XCTAssertEqual(String(highlighted.characters).count, lines.count)
    }

    func testRapidStreamingDeltas() async {
        let deltas = (0..<500).map { _ in "x" }
        var content = ""
        for d in deltas {
            content += d
        }
        XCTAssertEqual(content.count, 500)
    }
}
