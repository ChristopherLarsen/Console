import XCTest
@testable import Console

/// End-to-end hook-mode tests against the real embedded helper binary.
final class HelperHookFilteringTests: XCTestCase {

    private var server: SessionBridgeSocketServer!
    private var socketPath: String!
    private var received: [String] = []
    private let receivedLock = NSLock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        received = []

        let deliver: @Sendable (Data) -> Void = { [weak self] data in
            guard let self else { return }
            self.receivedLock.lock()
            self.received.append(String(data: data, encoding: .utf8) ?? "")
            self.receivedLock.unlock()
        }

        guard let socketURL = SessionBridgeSocketServer.makeProtectedSocketURL() else {
            XCTFail("could not create protected socket directory")
            throw XCTSkip("no usable socket location")
        }
        socketPath = socketURL.path
        let bridgeServer = SessionBridgeSocketServer(socketPath: socketPath, deliver: deliver)
        XCTAssertTrue(bridgeServer.start(), "test listener must start")
        server = bridgeServer
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    private var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path
    }

    /// Runs the helper in hook mode with a synthetic payload full of sensitive
    /// fields and fake secret values.
    @discardableResult
    private func runHelper(eventName: String, stdinJSON: String) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["hook", eventName]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        process.environment = [
            "CONSOLE_TERM_BRIDGE_SOCKET": socketPath,
            "CONSOLE_TERM_BRIDGE_SESSION_ID": UUID().uuidString,
            "CONSOLE_TERM_BRIDGE_TOKEN": "test-token-0123456789",
            // Coverage-instrumented builds print profraw errors to stderr when
            // the cwd is read-only; redirect coverage output to a temp file.
            "LLVM_PROFILE_FILE": NSTemporaryDirectory() + "hookfilter-\(UUID().uuidString).profraw",
            "TMPDIR": NSTemporaryDirectory(),
        ]

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func waitForEnvelope(timeout: TimeInterval = 5) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            receivedLock.lock()
            let current = received
            receivedLock.unlock()
            if let line = current.first, let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private let sensitiveUserPromptPayload = """
    {
      "session_id": "fake-session-abc",
      "transcript_path": "/Users/fake/.claude/projects/FAKE/00893aaf.jsonl",
      "cwd": "/Users/fake/Projects/FakeRepo",
      "permission_mode": "default",
      "hook_event_name": "UserPromptSubmit",
      "prompt": "FAKE-SECRET-PROMPT delete all production databases now"
    }
    """

    func testUserPromptSubmitForwardsWorkingWithoutPromptContent() throws {
        let (exitCode, _, _) = try runHelper(eventName: "UserPromptSubmit", stdinJSON: sensitiveUserPromptPayload)
        XCTAssertEqual(exitCode, EXIT_SUCCESS, "hook helper must always exit 0")
        let envelope = try XCTUnwrap(waitForEnvelope())

        XCTAssertEqual(envelope["kind"] as? String, "lifecycle")
        XCTAssertEqual(envelope["lifecycle_event"] as? String, "prompt_submitted")

        let serialized = (try? String(
            data: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? ""
        // Exact tokens: "prompt_submitted" is a legitimate reduced event name,
        // so only quoted field names and secret values count as leakage.
        for forbidden in [
            "\"prompt\"",
            "\"transcript_path\"",
            "FAKE-SECRET",
            "\"tool_input\"",
            "\"last_assistant_message\"",
            "delete all production databases",
        ] {
            XCTAssertFalse(serialized.contains(forbidden), "envelope must not contain \(forbidden)")
        }
    }

    func testStopFailureNeverCarriesAssistantMessage() throws {
        let payload = """
        {
          "session_id": "fake",
          "transcript_path": "/Users/fake/.claude/projects/x.jsonl",
          "cwd": "/tmp",
          "hook_event_name": "StopFailure",
          "error": "rate_limit",
          "error_details": "429 FAKE-SECRET-ERROR detail",
          "last_assistant_message": "API Error: FAKE-SECRET-ASSISTANT-TEXT"
        }
        """
        let (exitCode, _, _) = try runHelper(eventName: "StopFailure", stdinJSON: payload)
        XCTAssertEqual(exitCode, EXIT_SUCCESS, "hook helper must always exit 0")
        let envelope = try XCTUnwrap(waitForEnvelope())
        XCTAssertEqual(envelope["lifecycle_event"] as? String, "turn_failed")

        let serialized = (try? String(
            data: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? ""
        for forbidden in ["FAKE-SECRET", "last_assistant_message", "error_details", "transcript_path"] {
            XCTAssertFalse(serialized.contains(forbidden), "envelope must not contain \(forbidden)")
        }
    }

    func testCwdChangedForwardsOnlyNewDirectory() throws {
        let payload = """
        {
          "session_id": "fake",
          "transcript_path": "/Users/fake/.claude/projects/x.jsonl",
          "old_cwd": "/Users/fake/FakeOld FAKE-SECRET",
          "new_cwd": "/tmp/fake-new-dir",
          "hook_event_name": "CwdChanged"
        }
        """
        let (exitCode, _, _) = try runHelper(eventName: "CwdChanged", stdinJSON: payload)
        XCTAssertEqual(exitCode, EXIT_SUCCESS, "hook helper must always exit 0")
        let envelope = try XCTUnwrap(waitForEnvelope())
        XCTAssertEqual(envelope["kind"] as? String, "cwd")
        XCTAssertEqual(envelope["cwd_directory"] as? String, "/tmp/fake-new-dir")

        let serialized = (try? String(
            data: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? ""
        XCTAssertFalse(serialized.contains("FAKE-SECRET"))
        XCTAssertFalse(serialized.contains("transcript_path"))
    }

    func testPermissionRequestReducesToAttentionOnly() throws {
        let payload = """
        {
          "session_id": "fake",
          "transcript_path": "/Users/fake/.claude/projects/x.jsonl",
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "tool_input": {"command": "rm -rf /tmp/FAKE-SECRET-TARGET"},
          "permission_suggestions": [{"type": "addRules"}]
        }
        """
        let (exitCode, _, _) = try runHelper(eventName: "PermissionRequest", stdinJSON: payload)
        XCTAssertEqual(exitCode, EXIT_SUCCESS, "hook helper must always exit 0")
        let envelope = try XCTUnwrap(waitForEnvelope())
        XCTAssertEqual(envelope["kind"] as? String, "attention")
        XCTAssertEqual(envelope["attention_category"] as? String, "permission")
        XCTAssertNil(envelope["attention_message"])

        let serialized = (try? String(
            data: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? ""
        for forbidden in ["tool_input", "FAKE-SECRET", "\"tool_name\"", "permission_suggestions"] {
            XCTAssertFalse(serialized.contains(forbidden), "envelope must not contain \(forbidden)")
        }
    }

    func testAskUserQuestionMapsToQuestionAttention() throws {
        let payload = """
        {
          "session_id": "fake",
          "transcript_path": "/x.jsonl",
          "hook_event_name": "PreToolUse",
          "tool_name": "AskUserQuestion",
          "tool_input": {"questions": [{"question": "FAKE-SECRET-QUESTION?"}]}
        }
        """
        let (exitCode, _, _) = try runHelper(eventName: "AskUserQuestion", stdinJSON: payload)
        XCTAssertEqual(exitCode, EXIT_SUCCESS, "hook helper must always exit 0")
        let envelope = try XCTUnwrap(waitForEnvelope())
        XCTAssertEqual(envelope["attention_category"] as? String, "question")
        XCTAssertNil(envelope["attention_message"])
    }

    func testHookModeAlwaysExitsZeroAndPrintsNothing() throws {
        let (code, stdout, stderr) = try runHelper(
            eventName: "SessionStart",
            stdinJSON: "{\"session_id\":\"fake\",\"transcript_path\":\"/t\",\"hook_event_name\":\"SessionStart\"}"
        )
        XCTAssertEqual(code, EXIT_SUCCESS)
        XCTAssertEqual(stdout, "", "hook mode must never print to stdout")
        XCTAssertEqual(stderr, "", "hook mode must never print to stderr")
    }

    func testUnknownEventStillExitsZeroSilently() throws {
        let (code, stdout, stderr) = try runHelper(
            eventName: "SomeFutureEvent",
            stdinJSON: "{\"session_id\":\"fake\"}"
        )
        XCTAssertEqual(code, EXIT_SUCCESS)
        XCTAssertEqual(stdout, "")
        XCTAssertEqual(stderr, "")
        // Give the listener a moment; nothing should arrive.
        Thread.sleep(forTimeInterval: 0.2)
        receivedLock.lock()
        let count = received.count
        receivedLock.unlock()
        XCTAssertEqual(count, 0)
    }

    func testGarbageStdinStillExitsZeroSilently() throws {
        let (code, stdout, stderr) = try runHelper(
            eventName: "CwdChanged",
            stdinJSON: "this is not json at all"
        )
        XCTAssertEqual(code, EXIT_SUCCESS)
        XCTAssertEqual(stdout, "")
        XCTAssertEqual(stderr, "")
    }
}
