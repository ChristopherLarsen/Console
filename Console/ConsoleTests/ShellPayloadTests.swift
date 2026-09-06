import XCTest
@testable import Console

final class ShellPayloadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Legacy quoting

    func testLegacySimpleCommandSplitsOnSpaces() throws {
        let payload = try ShellPayload.parseLegacyCommandLine("open -a Safari")
        XCTAssertEqual(payload.command, "open")
        XCTAssertEqual(payload.args, ["-a", "Safari"])
        XCTAssertNil(payload.workingDirectory)
    }

    func testPathsAndSchemeNamesWithSpacesStayIntact() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(
            #"xcodebuild -scheme "My App" -project "/tmp/My Project/App.xcodeproj""#
        )
        XCTAssertEqual(payload.command, "xcodebuild")
        XCTAssertEqual(payload.args, ["-scheme", "My App", "-project", "/tmp/My Project/App.xcodeproj"])
    }

    func testEmptySingleAndDoubleQuotedArguments() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(#"echo '' "" keep"#)
        XCTAssertEqual(payload.command, "echo")
        XCTAssertEqual(payload.args, ["", "", "keep"])
    }

    func testEscapedQuotesInDoubleQuotes() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(#"echo "say \"hello\"""#)
        XCTAssertEqual(payload.command, "echo")
        XCTAssertEqual(payload.args, [#"say "hello""#])
    }

    func testUnquotedEscapedQuotesAreLiteral() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(#"echo \"quoted\""#)
        XCTAssertEqual(payload.command, "echo")
        XCTAssertEqual(payload.args, ["\"quoted\""])
    }

    func testUnicodeArgumentsArePreserved() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(#"echo "café こんにちは 🎯""#)
        XCTAssertEqual(payload.command, "echo")
        XCTAssertEqual(payload.args, ["café こんにちは 🎯"])
    }

    func testEscapedSpaceIsOneArgument() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(#"open /tmp/My\ Project/App.xcodeproj"#)
        XCTAssertEqual(payload.command, "open")
        XCTAssertEqual(payload.args, ["/tmp/My Project/App.xcodeproj"])
    }

    func testSingleQuotesPreserveOperatorsLiterally() throws {
        let payload = try ShellPayload.parseLegacyCommandLine(#"echo 'a|b && c'"#)
        XCTAssertEqual(payload.args, ["a|b && c"])
    }

    func testMultipleSpacesDoNotCreateEmptyArguments() throws {
        let payload = try ShellPayload.parseLegacyCommandLine("open  -a   Safari")
        XCTAssertEqual(payload.command, "open")
        XCTAssertEqual(payload.args, ["-a", "Safari"])
    }

    // MARK: - Unsupported operators

    func testPipeIsRejected() {
        assertUnsupportedOperator("echo hello | cat", operator: "|")
    }

    func testAndAndOrAreRejected() {
        assertUnsupportedOperator("echo a && echo b", operator: "&&")
        assertUnsupportedOperator("echo a || echo b", operator: "||")
    }

    func testRedirectionIsRejected() {
        assertUnsupportedOperator("echo hi > /tmp/out", operator: ">")
        assertUnsupportedOperator("cat < /tmp/in", operator: "<")
    }

    func testVariableExpansionIsRejected() {
        assertUnsupportedOperator("echo $HOME", operator: "$")
        assertUnsupportedOperator(#"echo "$(pwd)""#, operator: "$(")
    }

    func testBackticksAreRejected() {
        assertUnsupportedOperator("echo `pwd`", operator: "`")
    }

    func testSemicolonIsRejected() {
        assertUnsupportedOperator("echo a; echo b", operator: ";")
    }

    func testUnbalancedQuotesAreRejected() {
        XCTAssertThrowsError(try ShellPayload.parseLegacyCommandLine(#"echo "hello"#)) { error in
            XCTAssertEqual(error as? ShellPayloadError, .unterminatedQuote("double"))
        }
        XCTAssertThrowsError(try ShellPayload.parseLegacyCommandLine("echo 'hello")) { error in
            XCTAssertEqual(error as? ShellPayloadError, .unterminatedQuote("single"))
        }
    }

    // MARK: - Structured contract

    func testStructuredPayloadKeepsExactArgvAndWorkingDirectory() {
        let payload = ShellPayload.structured(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "My App", ""],
            workingDirectory: "/tmp/My Project"
        )
        XCTAssertEqual(payload.command, "/usr/bin/xcodebuild")
        XCTAssertEqual(payload.args, ["-scheme", "My App", ""])
        XCTAssertEqual(payload.workingDirectory, "/tmp/My Project")
        XCTAssertEqual(
            payload.processLaunch,
            ProcessLaunchSpec(
                executablePath: "/usr/bin/xcodebuild",
                arguments: ["-scheme", "My App", ""],
                workingDirectory: "/tmp/My Project"
            )
        )
    }

    func testRelativeCommandUsesEnvForPATHLookup() {
        let launch = ShellPayload.structured(executable: "open", arguments: ["-a", "Safari"]).processLaunch
        XCTAssertEqual(launch.executablePath, "/usr/bin/env")
        XCTAssertEqual(launch.arguments, ["open", "-a", "Safari"])
        XCTAssertNil(launch.workingDirectory)
    }

    func testResolveDecodesStructuredJSON() throws {
        let json = """
        {"command":"xcodebuild","args":["-scheme","My App"],"workingDirectory":"/tmp/My Project"}
        """
        let payload = try ShellPayload.resolve(json)
        XCTAssertEqual(payload.command, "xcodebuild")
        XCTAssertEqual(payload.args, ["-scheme", "My App"])
        XCTAssertEqual(payload.workingDirectory, "/tmp/My Project")
    }

    func testResolveDecodesExecutableArgumentsAliases() throws {
        let json = """
        {"executable":"/usr/bin/xcodebuild","arguments":["-scheme","My App"],"workingDirectory":"/tmp/My Project"}
        """
        let payload = try ShellPayload.resolve(json)
        XCTAssertEqual(payload.command, "/usr/bin/xcodebuild")
        XCTAssertEqual(payload.args, ["-scheme", "My App"])
        XCTAssertEqual(payload.processLaunch.executablePath, "/usr/bin/xcodebuild")
    }

    func testResolveDecodesLegacyStringWhenNotJSONObject() throws {
        let payload = try ShellPayload.resolve(#"open -a "My App""#)
        XCTAssertEqual(payload.command, "open")
        XCTAssertEqual(payload.args, ["-a", "My App"])
    }

    func testJSONDecoderAcceptsLegacyStringCommand() throws {
        let data = Data(#""open -a Safari""#.utf8)
        let payload = try JSONDecoder().decode(ShellPayload.self, from: data)
        XCTAssertEqual(payload.command, "open")
        XCTAssertEqual(payload.args, ["-a", "Safari"])
    }

    func testJSONDecoderAcceptsStructuredObject() throws {
        let data = Data(#"{"command":"echo","args":["hello"]}"#.utf8)
        let payload = try JSONDecoder().decode(ShellPayload.self, from: data)
        XCTAssertEqual(payload.command, "echo")
        XCTAssertEqual(payload.args, ["hello"])
    }

    func testInvalidStructuredJSONIsRejected() {
        XCTAssertThrowsError(try ShellPayload.resolve("{not-json")) { error in
            XCTAssertEqual(error as? ShellPayloadError, .invalidStructuredPayload)
        }
        XCTAssertThrowsError(try ShellPayload.resolve(#"{"args":["-scheme"]}"#)) { error in
            XCTAssertEqual(error as? ShellPayloadError, .missingCommand)
        }
    }

    func testCommandActionDecodesStructuredPayloadObject() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "type": "shell",
          "payload": {
            "command": "xcodebuild",
            "args": ["-scheme", "My App"],
            "workingDirectory": "/tmp/My Project"
          },
          "order": 0,
          "delayAfterMS": 500,
          "timeoutMS": 5000,
          "retryOnFailure": false
        }
        """
        let action = try JSONDecoder().decode(CommandAction.self, from: Data(json.utf8))
        let payload = try action.resolvedShellPayload()
        XCTAssertEqual(payload.command, "xcodebuild")
        XCTAssertEqual(payload.args, ["-scheme", "My App"])
        XCTAssertEqual(payload.workingDirectory, "/tmp/My Project")
    }

    func testCommandActionRoundTripPreservesLegacyString() throws {
        let original = CommandAction(type: .shell, payload: #"open -a "My App""#, order: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommandAction.self, from: data)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(try decoded.resolvedShellPayload().args, ["-a", "My App"])
    }

    func testIOSJobContractDoesNotParseArgumentsAsShell() {
        let payload = ShellPayload.structured(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "My App", "a|b", "$HOME"],
            workingDirectory: "/tmp/My Project"
        )
        XCTAssertEqual(payload.args, ["-scheme", "My App", "a|b", "$HOME"])
        XCTAssertEqual(payload.processLaunch.arguments, payload.args)
    }

    // MARK: - Validation uses the same representation

    func testValidationAcceptsQuotedLegacyCommand() {
        let result = validate("open -a \"My App\"")
        XCTAssertTrue(result.isSuccess, "Unexpected validation result: \(result)")
    }

    func testValidationRejectsUnsupportedOperatorsBeforeAllowlist() {
        let result = validate("echo hello | cat")
        guard case .failure(let message) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Unsupported shell operator"), message)
        XCTAssertTrue(message.contains("|"), message)
    }

    func testValidationAndResolveProduceTheSameArgv() throws {
        let line = #"open -a "My App""#
        let parsed = try ShellPayload.resolve(line)
        let result = validate(line)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(parsed.command, "open")
        XCTAssertEqual(parsed.args, ["-a", "My App"])
    }

    func testValidationAcceptsStructuredOpenPayload() {
        let payload = ShellPayload.structured(
            executable: "open",
            arguments: ["-a", "My App"],
            workingDirectory: "/tmp/My Project"
        )
        let result = validate(payload.encodedJSONString())
        XCTAssertTrue(result.isSuccess, "Unexpected validation result: \(result)")
    }

    // MARK: - Helpers

    private func assertUnsupportedOperator(_ line: String, operator token: String) {
        XCTAssertThrowsError(try ShellPayload.parseLegacyCommandLine(line), line) { error in
            guard let payloadError = error as? ShellPayloadError,
                  case .unsupportedOperator(let found) = payloadError else {
                return XCTFail("Expected unsupportedOperator, got \(error)")
            }
            XCTAssertEqual(found, token)
            XCTAssertTrue(
                payloadError.localizedDescription.contains("argument array"),
                payloadError.localizedDescription
            )
        }
    }

    private func validate(_ payload: String) -> ValidationResult {
        let command = Command(
            name: "Synthetic Shell Validation",
            actions: [CommandAction(type: .shell, payload: payload, order: 0)]
        )
        return CommandValidator().validateCommand(command)
    }
}
