import XCTest
@testable import Console

final class AppleScriptRunnerTests: XCTestCase {

    func testOpenURLEscapesBackslashesBeforeQuotes() async throws {
        let runner = ScriptCapturingRunner()
        let injected = #"https://example.com/synthetic\" & do shell script "echo pwned" & \""#

        _ = try await AppleScriptRunner.openURL(injected, processRunner: runner)

        XCTAssertEqual(runner.scripts.count, 1)
        // Input `\"` must survive as `\\\"` inside the osascript string literal.
        XCTAssertEqual(
            runner.scripts[0],
            "open location \"https://example.com/synthetic\\\\\\\" & do shell script \\\"echo pwned\\\" & \\\\\\\"\""
        )
    }

    func testOpenURLPassesPlainURLThroughUnchanged() async throws {
        let runner = ScriptCapturingRunner()

        _ = try await AppleScriptRunner.openURL("https://example.com/path?q=synthetic", processRunner: runner)

        XCTAssertEqual(runner.scripts, ["open location \"https://example.com/path?q=synthetic\""])
    }

    func testOpenURLEmptyParameterIsRejected() async {
        do {
            _ = try await AppleScriptRunner.openURL("   ", processRunner: ScriptCapturingRunner())
            XCTFail("Expected invalidParameter for empty URL")
        } catch let error as AppleScriptRunner.ScriptError {
            guard case .invalidParameter = error else {
                XCTFail("Expected .invalidParameter, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class ScriptCapturingRunner: ProcessRunning, @unchecked Sendable {
    private(set) var scripts: [String] = []

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        if let index = arguments.firstIndex(of: "-e"), index + 1 < arguments.count {
            scripts.append(arguments[index + 1])
        }
        return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
