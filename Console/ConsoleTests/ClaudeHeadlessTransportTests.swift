import XCTest
@testable import Console

// MARK: - Shared fakes

/// Canned `--help` output advertising every flag the feature may use, so
/// flag validation passes deterministically in tests.
enum StubCLI {
    static let helpOutput = """
    Claude Code - starts an interactive session by default, use -p/--print for
    non-interactive output
      -p, --print                          Print response without interactive mode
      --output-format <format>             Output format (only works with --print)
      --input-format <format>              Input format (only works with --print)
      --session-id <uuid>                  Use a specific session ID
      --resume <session-id>                Resume a session
      --no-session-persistence             Do not persist the session
      --max-turns <n>                      Cap agent turns
      --tools <tools...>                   Restrict built-in tools
      --permission-prompts <target>        Who answers permission prompts
      --json-schema <schema>               Validate the response shape
      --model <model>                      Model for the current session
      --mcp-config <configs...>            Load MCP servers from JSON
      --strict-mcp-config                  Only use MCP servers from --mcp-config
      --allowedTools, --allowed-tools      Allowed tools
    """

    /// Writes a stub executable that prints `helpOutput` for `--help` and a
    /// fixed result envelope for anything else. Used by `prepare()`'s real
    /// `--help` probe so unit tests never depend on the host installation.
    static func makeExecutable(
        directory: URL,
        helpText: String = helpOutput,
        runResult: String = ""
    ) throws -> String {
        let path = directory.appendingPathComponent("stub-claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
        cat <<'HELPEOF'
        \(helpText)
        HELPEOF
        exit 0
        fi
        cat <<'RUNEOF'
        \(runResult)
        RUNEOF
        exit 0
        """
        try script.data(using: .utf8)!.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    /// Builds a headless stdout envelope whose structured result echoes the
    /// correlation ID found in the prompt (the same contract the real CLI is
    /// instructed to follow).
    static func envelope(
        promptText: String,
        resultOverride: String? = nil,
        isError: Bool = false
    ) -> String {
        let correlationID = Self.correlationID(in: promptText) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let result = resultOverride ?? """
        {"schemaVersion":1,"correlationID":"\(correlationID)","operation":"ping"}
        """
        let object: [String: Any] = [
            "type": "result",
            "subtype": isError ? "error_during_execution" : "success",
            "is_error": isError,
            "result": result,
            "session_id": "22222222-2222-2222-2222-222222222222",
        ]
        return try! String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// Rewrites the structured result's correlationID so it echoes the
    /// request prompt, matching the real CLI contract.
    static func replacingCorrelationID(in result: String, with id: UUID) -> String {
        result.replacingOccurrences(
            of: #""correlationID":"[0-9A-Fa-f-]{36}""#,
            with: "\"correlationID\":\"\(id.uuidString)\"",
            options: .regularExpression
        )
    }

    static func correlationID(in prompt: String) -> UUID? {
        guard let range = prompt.range(of: #""correlationID":"([0-9A-Fa-f-]{36})""#, options: .regularExpression) else {
            return nil
        }
        let match = prompt[range]
        let idPart = match.split(separator: "\"").last.map(String.init) ?? ""
        return UUID(uuidString: idPart)
    }

    static func structuredResult(
        operation: String,
        correlationID: UUID,
        ticketKey: String? = nil,
        statusName: String? = nil,
        transitions: [[String: String]]? = nil,
        results: [[String: String]]? = nil,
        appliedTransitionID: String? = nil
    ) -> String {
        var fields = [
            "\"schemaVersion\":1",
            "\"correlationID\":\"\(correlationID.uuidString)\"",
            "\"operation\":\"\(operation)\"",
        ]
        if let ticketKey { fields.append("\"ticketKey\":\"\(ticketKey)\"") }
        if let statusName { fields.append("\"statusName\":\"\(statusName)\"") }
        if let transitions {
            let encoded = transitions.map { entry in
                "{\"id\":\"\(entry["id"] ?? "")\",\"name\":\"\(entry["name"] ?? "")\",\"targetStatusName\":\"\(entry["targetStatusName"] ?? "")\"}"
            }.joined(separator: ",")
            fields.append("\"transitions\":[\(encoded)]")
        }
        if let results {
            let encoded = results.map { entry in
                "{\"key\":\"\(entry["key"] ?? "")\",\"statusName\":\"\(entry["statusName"] ?? "")\"}"
            }.joined(separator: ",")
            fields.append("\"results\":[\(encoded)]")
        }
        if let appliedTransitionID {
            fields.append("\"appliedTransitionID\":\"\(appliedTransitionID)\"")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// Scripted transport for `ManagedClaudeService`: pops outcomes in order and
/// records requests. Concurrency is tracked so serialization is assertable.
final class FakeHeadlessTransport: ClaudeHeadlessTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [ClaudeHeadlessRequest] = []
    private var active = 0
    private(set) var maxConcurrency = 0
    /// Hangs the next operation until `release` is called.
    private var hangNext = false
    private var pendingContinuations: [CheckedContinuation<ClaudeHeadlessOutcome, Never>] = []
    private var behaviors: [@Sendable (ClaudeHeadlessRequest) async -> ClaudeHeadlessOutcome] = []

    func enqueue(_ outcome: ClaudeHeadlessOutcome) {
        enqueueBehavior { _ in outcome }
    }

    func enqueueSuccess(result: String) {
        enqueueBehavior { request in
            let echo = StubCLI.correlationID(in: request.standardInputText) ?? UUID()
            let fixed = StubCLI.replacingCorrelationID(in: result, with: echo)
            return .success(
                stdout: StubCLI.envelope(promptText: request.standardInputText, resultOverride: fixed),
                stderr: nil
            )
        }
    }

    func enqueueBehavior(_ behavior: @escaping @Sendable (ClaudeHeadlessRequest) async -> ClaudeHeadlessOutcome) {
        lock.lock()
        behaviors.append(behavior)
        lock.unlock()
    }


    func hangNextRun() {
        lock.lock()
        hangNext = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        hangNext = false
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: .success(stdout: StubCLI.envelope(promptText: ""), stderr: nil))
        }
    }

    func run(_ request: ClaudeHeadlessRequest) async -> ClaudeHeadlessOutcome {
        lock.lock()
        requests.append(request)
        let behavior = behaviors.isEmpty ? nil : behaviors.removeFirst()
        let shouldHang = hangNext
        active += 1
        maxConcurrency = max(maxConcurrency, active)
        lock.unlock()

        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }

        if shouldHangWait() {
            return await withCheckedContinuation { (continuation: CheckedContinuation<ClaudeHeadlessOutcome, Never>) in
                lock.lock()
                pendingContinuations.append(continuation)
                lock.unlock()
            }
        }

        if let behavior {
            return await behavior(request)
        }
        return ClaudeHeadlessOutcome(dispatched: false, stdout: nil, stderr: nil, failure: .launchFailed(reason: "no scripted behavior"))
    }

    private func shouldHangWait() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hangNext
    }

    func concurrencyCapped(at limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return maxConcurrency <= limit
    }
}

// MARK: - Transport tests

final class ClaudeHeadlessTransportUnitTests: XCTestCase {

    func testFlagCatalogExtractsFlagsFromHelpText() {
        let flags = ClaudeFlagCatalog.supportedFlags(fromHelp: StubCLI.helpOutput)
        XCTAssertTrue(flags.contains("--print"))
        XCTAssertTrue(flags.contains("--output-format"))
        XCTAssertTrue(flags.contains("--session-id"))
        XCTAssertTrue(flags.contains("--strict-mcp-config"))
        XCTAssertTrue(ClaudeFlagCatalog.missingRequiredFlags(in: flags).isEmpty)
    }

    func testFlagCatalogDetectsMissingMandatoryFlags() {
        let flags = ClaudeFlagCatalog.supportedFlags(fromHelp: "usage: claude\n  --print  Print")
        XCTAssertEqual(ClaudeFlagCatalog.missingRequiredFlags(in: flags), ["--output-format"])
    }

    func testBuilderFreshRunUsesExplicitSessionID() {
        let sessionID = UUID()
        let build = HeadlessInvocationBuilder.arguments(
            options: .init(
                model: nil,
                maxTurns: 4,
                allowedTools: [],
                sessionID: sessionID,
                resume: false,
                ephemeral: true,
                expectedSchemaJSON: nil,
                mcpConfigPath: nil
            ),
            supportedFlags: ClaudeFlagCatalog.supportedFlags(fromHelp: StubCLI.helpOutput)
        )
        XCTAssertTrue(build.arguments.contains("--session-id"))
        XCTAssertTrue(build.arguments.contains(sessionID.uuidString))
        XCTAssertFalse(build.arguments.contains("--resume"))
        XCTAssertFalse(build.arguments.contains("--continue"))
        // Ephemeral managed runs persist no session.
        XCTAssertTrue(build.arguments.contains("--no-session-persistence"))
        // Tool surface pinned to nothing.
        XCTAssertTrue(build.arguments.contains("--strict-mcp-config"))
    }

    func testBuilderResumeUsesOwnedSessionIDAndNeverContinue() {
        let sessionID = UUID()
        let build = HeadlessInvocationBuilder.arguments(
            options: .init(
                model: nil,
                maxTurns: 4,
                allowedTools: [],
                sessionID: sessionID,
                resume: true,
                ephemeral: false,
                expectedSchemaJSON: nil,
                mcpConfigPath: nil
            ),
            supportedFlags: ClaudeFlagCatalog.supportedFlags(fromHelp: StubCLI.helpOutput)
        )
        XCTAssertTrue(build.arguments.contains("--resume"))
        // The resume value is the owned session ID, positioned right after
        // the flag.
        if let flagIndex = build.arguments.firstIndex(of: "--resume") {
            XCTAssertEqual(build.arguments[flagIndex + 1], sessionID.uuidString)
        } else {
            XCTFail("--resume missing")
        }
        XCTAssertFalse(build.arguments.contains("--continue"))
    }

    func testBuilderDropsUnsupportedOptionalFlags() {
        let build = HeadlessInvocationBuilder.arguments(
            options: .init(
                model: "sonnet",
                maxTurns: 4,
                allowedTools: [],
                sessionID: UUID(),
                resume: false,
                ephemeral: true,
                expectedSchemaJSON: nil,
                mcpConfigPath: nil
            ),
            supportedFlags: ["--print", "--output-format", "--session-id", "--mcp-config", "--strict-mcp-config", "--tools"]
        )
        XCTAssertTrue(build.droppedFlags.contains("--max-turns"))
        XCTAssertFalse(build.arguments.contains("--max-turns"))
    }

    func testAuthenticationFailureClassification() {
        XCTAssertTrue(HeadlessProcessTransport.looksLikeAuthenticationFailure("Error: Invalid API key. Please run /login"))
        XCTAssertFalse(HeadlessProcessTransport.looksLikeAuthenticationFailure("file not found"))
    }

    func testSanitizedMessageIsBounded() {
        let long = (0..<500).map { "line\($0)" }.joined(separator: "\n")
        let sanitized = HeadlessProcessTransport.sanitizedMessage(stdout: long, stderr: nil)
        XCTAssertLessThanOrEqual(sanitized.count, 400)
    }

    func testContinuationGateClaimsExactlyOnce() {
        let gate = ContinuationGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
    }
}
