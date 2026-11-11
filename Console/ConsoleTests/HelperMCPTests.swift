import XCTest
@testable import Console

/// End-to-end MCP-mode tests against the real embedded helper binary.
final class HelperMCPTests: XCTestCase {

    private var process: Process!
    private var stdinHandle: FileHandle!
    private var stdoutReader: LinePoller!
    private var server: SessionBridgeSocketServer!
    private var received: [String] = []
    private let receivedLock = NSLock()
    private var resultsDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        received = []

        guard let socketURL = SessionBridgeSocketServer.makeProtectedSocketURL() else {
            throw XCTSkip("no usable socket location")
        }
        let resultsDir = URL(fileURLWithPath: socketURL.path)
            .deletingLastPathComponent()
            .appendingPathComponent("mcp-results", isDirectory: true)
        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        resultsDirectory = resultsDir

        // Production socket path: the helper must deliver valid tool calls to
        // a real SessionBridgeSocketServer, not silently drop them. For tools
        // that wait on result files, write a synthetic success result.
        let deliver: @Sendable (Data) -> Void = { [weak self] data in
            guard let self else { return }
            self.receivedLock.lock()
            self.received.append(String(data: data, encoding: .utf8) ?? "")
            self.receivedLock.unlock()
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let requestID = object["request_id"] as? String,
               !requestID.isEmpty {
                let payload: [String: Any] = [
                    "ok": true,
                    "session_id": object["target_session_id"] as? String
                        ?? "33333333-3333-3333-3333-333333333333",
                ]
                if let resultData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                    try? resultData.write(
                        to: resultsDir.appendingPathComponent("\(requestID).json"),
                        options: .atomic
                    )
                }
            }
        }

        let bridgeServer = SessionBridgeSocketServer(socketPath: socketURL.path, deliver: deliver)
        XCTAssertTrue(bridgeServer.start(), "test listener must start")
        server = bridgeServer

        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path
        guard FileManager.default.fileExists(atPath: helperPath) else {
            server.stop()
            server = nil
            throw XCTSkip("helper not built into host app bundle")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = ["mcp"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe

        // MCP mode must never write diagnostics to stderr; capture to assert.
        let stderrPipe = Pipe()
        p.standardError = stderrPipe

        let snapshotURL = URL(fileURLWithPath: socketURL.path)
            .deletingLastPathComponent()
            .appendingPathComponent("sessions.json")
        let snapshot: [[String: Any]] = [
            [
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "Orchestrator",
                "purpose": "orchestrator",
                "activity": "idle",
                "attention": "none",
                "bridge_status": "active",
                "artifacts": [],
            ],
            [
                "id": "22222222-2222-2222-2222-222222222222",
                "name": "Worker",
                "purpose": "general",
                "activity": "working",
                "attention": "none",
                "bridge_status": "active",
                "summary": "Implementing login",
                "artifacts": [["kind": "jira_issue", "label": "NMA-1"]],
            ],
        ]
        let snapshotData = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        try snapshotData.write(to: snapshotURL, options: .atomic)

        p.environment = [
            "CONSOLE_TERM_BRIDGE_SOCKET": socketURL.path,
            "CONSOLE_TERM_BRIDGE_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "CONSOLE_TERM_BRIDGE_TOKEN": "test-token-0123456789",
            "CONSOLE_SESSIONS_SNAPSHOT": snapshotURL.path,
            "CONSOLE_MCP_RESULTS_DIR": resultsDir.path,
            // Coverage-instrumented builds print profraw errors to stderr when
            // the cwd is read-only; redirect coverage output to a temp file.
            "LLVM_PROFILE_FILE": NSTemporaryDirectory() + "mcp-\(UUID().uuidString).profraw",
        ]

        try p.run()
        process = p
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutReader = LinePoller(handle: stdoutPipe.fileHandleForReading)
    }

    override func tearDownWithError() throws {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    /// Bounded wait for the first envelope the helper delivered over the
    /// production socket, decoded as JSON.
    private func waitForDeliveredEnvelope(timeout: TimeInterval = 5) throws -> [String: Any]? {
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

    /// Bounded assertion that nothing was delivered over the socket.
    private func assertNothingDelivered(timeout: TimeInterval = 0.5) {
        Thread.sleep(forTimeInterval: timeout)
        receivedLock.lock()
        let count = received.count
        receivedLock.unlock()
        XCTAssertEqual(count, 0, "no envelope may be delivered over the socket")
    }

    @discardableResult
    private func send(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var line = data
        line.append(UInt8(ascii: "\n"))
        stdinHandle.write(line)
        return try nextResponse()
    }

    private func nextResponse() throws -> [String: Any] {
        let line = try XCTUnwrap(stdoutReader.readLine(timeout: 5), "expected a response line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    // MARK: - Lifecycle

    func testInitializeHandshake() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ])
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "console-bridge")
        XCTAssertNotNil(result["capabilities"])
    }

    func testInitializedNotificationProducesNoOutput() throws {
        _ = try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ])
        // Notifications are written without awaiting any response.
        var notification = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]
        )
        notification.append(UInt8(ascii: "\n"))
        stdinHandle.write(notification)
        XCTAssertNil(stdoutReader.readLine(timeout: 0.5), "notifications must not be answered")
    }

    func testPing() throws {
        let response = try send(["jsonrpc": "2.0", "id": 7, "method": "ping"])
        XCTAssertEqual(response["id"] as? Int, 7)
        XCTAssertNotNil(response["result"])
        XCTAssertNil(response["error"])
    }

    // MARK: - Tool listing

    func testToolsListExposesConsoleTools() throws {
        let response = try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "report_attention",
            "link_artifact",
            "report_completion",
            "list_console_sessions",
            "create_console_session",
            "close_console_session",
            "prompt_console_session",
        ])

        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"], "\(tool) must declare an input schema")
            XCTAssertNotNil(tool["description"])
        }
    }

    // MARK: - Tool calls (socket-backed: valid calls must reach the test
    // listener as reduced envelopes; rejected calls must deliver nothing)

    func testValidReportCompletionCallSucceeds() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "report_completion",
                "arguments": ["outcome": "completed", "summary": "Refactor finished, tests green."],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "ok")

        let envelope = try XCTUnwrap(waitForDeliveredEnvelope(), "valid completion must be delivered over the socket")
        XCTAssertEqual(envelope["kind"] as? String, "completion")
        XCTAssertEqual(envelope["completion_outcome"] as? String, "completed")
        XCTAssertEqual(envelope["completion_summary"] as? String, "Refactor finished, tests green.")
    }

    func testValidReportAttentionCallSucceeds() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": [
                "name": "report_attention",
                "arguments": ["category": "question", "message": "Which database should I use?"],
            ],
        ])
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)

        let envelope = try XCTUnwrap(waitForDeliveredEnvelope(), "valid attention must be delivered over the socket")
        XCTAssertEqual(envelope["kind"] as? String, "attention")
        XCTAssertEqual(envelope["attention_category"] as? String, "question")
    }

    func testValidLinkArtifactDeliversArtifactEnvelope() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 8,
            "method": "tools/call",
            "params": [
                "name": "link_artifact",
                "arguments": ["kind": "jira_issue", "label": "FAKE-1", "url": "https://example.test/browse/FAKE-1"],
            ],
        ])
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)

        let envelope = try XCTUnwrap(waitForDeliveredEnvelope(), "valid artifact link must be delivered over the socket")
        XCTAssertEqual(envelope["kind"] as? String, "artifact")
        XCTAssertEqual(envelope["artifact_kind"] as? String, "jira_issue")
        XCTAssertEqual(envelope["artifact_label"] as? String, "FAKE-1")
        XCTAssertEqual(envelope["artifact_url"] as? String, "https://example.test/browse/FAKE-1")
    }

    func testListConsoleSessionsReadsSnapshot() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": [
                "name": "list_console_sessions",
                "arguments": [:],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("Orchestrator"))
        XCTAssertTrue(text.contains("Worker"))
        assertNothingDelivered()
    }

    func testCreateConsoleSessionDeliversEnvelope() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 21,
            "method": "tools/call",
            "params": [
                "name": "create_console_session",
                "arguments": [
                    "purpose": "general",
                    "name": "Helper",
                    "initial_prompt": "Start the helper task",
                ],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"ok\":true") || text.contains("\"ok\" : true"))
        let envelope = try XCTUnwrap(waitForDeliveredEnvelope(), "create must be delivered")
        XCTAssertEqual(envelope["kind"] as? String, "create_session")
        XCTAssertEqual(envelope["create_purpose"] as? String, "general")
        XCTAssertEqual(envelope["create_name"] as? String, "Helper")
        XCTAssertEqual(envelope["create_initial_prompt"] as? String, "Start the helper task")
        XCTAssertNotNil(envelope["request_id"] as? String)
    }

    func testCloseConsoleSessionRefusesSelf() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 22,
            "method": "tools/call",
            "params": [
                "name": "close_console_session",
                "arguments": ["session_id": "11111111-1111-1111-1111-111111111111"],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains("refused") == true)
        assertNothingDelivered()
    }

    func testCloseConsoleSessionDeliversEnvelope() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 23,
            "method": "tools/call",
            "params": [
                "name": "close_console_session",
                "arguments": ["session_id": "22222222-2222-2222-2222-222222222222"],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"ok\":true") || text.contains("\"ok\" : true"))
        let envelope = try XCTUnwrap(waitForDeliveredEnvelope(), "close must be delivered")
        XCTAssertEqual(envelope["kind"] as? String, "close_session")
        XCTAssertEqual(envelope["target_session_id"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertNotNil(envelope["request_id"] as? String)
    }

    func testPromptConsoleSessionDeliversEnvelope() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 24,
            "method": "tools/call",
            "params": [
                "name": "prompt_console_session",
                "arguments": [
                    "session_id": "22222222-2222-2222-2222-222222222222",
                    "prompt": "Continue the login work",
                ],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"ok\":true") || text.contains("\"ok\" : true"))
        let envelope = try XCTUnwrap(waitForDeliveredEnvelope(), "prompt must be delivered")
        XCTAssertEqual(envelope["kind"] as? String, "prompt_session")
        XCTAssertEqual(envelope["target_session_id"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(envelope["prompt_text"] as? String, "Continue the login work")
    }

    func testListConsoleSessionsIncludesEnrichedFields() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 25,
            "method": "tools/call",
            "params": [
                "name": "list_console_sessions",
                "arguments": [:],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("bridge_status"))
        XCTAssertTrue(text.contains("Implementing login"))
        XCTAssertTrue(text.contains("NMA-1"))
    }

    func testInvalidCategoryIsToolError() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": [
                "name": "report_attention",
                "arguments": ["category": "urgent", "message": "hi"],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        assertNothingDelivered()
    }

    func testOversizedMessageRejected() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": [
                "name": "report_completion",
                "arguments": ["outcome": "completed", "summary": String(repeating: "x", count: 401)],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains("400") == true)
        assertNothingDelivered()
    }

    func testJiraArtifactRejectsGitLabURL() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": [
                "name": "link_artifact",
                "arguments": [
                    "kind": "jira_issue",
                    "label": "ENG-42",
                    "url": "https://gitlab.example.test/team/app/-/merge_requests/42",
                ],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains("JIRA") == true)
        assertNothingDelivered()
    }

    func testGitLabArtifactRejectsJiraURL() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 14,
            "method": "tools/call",
            "params": [
                "name": "link_artifact",
                "arguments": [
                    "kind": "gitlab_merge_request",
                    "label": "MR !42",
                    "url": "https://jira.example.test/browse/ENG-42",
                ],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains("GitLab") == true)
        assertNothingDelivered()
    }

    func testNonHTTPSURLRejected() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": [
                "name": "link_artifact",
                "arguments": ["kind": "jira_issue", "label": "FAKE-1", "url": "http://example.com/x"],
            ],
        ])
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        assertNothingDelivered()
    }

    func testUnknownToolReturnsToolError() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": ["name": "delete_everything", "arguments": [:]],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testUnknownMethodIsProtocolError() throws {
        let response = try send(["jsonrpc": "2.0", "id": 11, "method": "resources/list"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testMalformedLineGetsParseErrorAndServerSurvives() throws {
        var garbage = Data("this is not json\n".utf8)
        stdinHandle.write(garbage)
        let errorResponse = try nextResponse()
        XCTAssertEqual(((errorResponse["error"] as? [String: Any])?["code"] as? Int), -32700)

        garbage = Data()
        _ = try send(["jsonrpc": "2.0", "id": 12, "method": "ping"])
    }

    func testCleanNewlineDelimitedFraming() throws {
        for index in 0..<5 {
            let response = try send(["jsonrpc": "2.0", "id": index, "method": "ping"])
            XCTAssertEqual(response["id"] as? Int, index, "each request gets exactly one framed response")
        }
    }
}

/// Polls a file handle for newline-delimited lines with a timeout, using a
/// dedicated reader thread so blocking reads never stall the test.
final class LinePoller {
    private let handle: FileHandle
    private var buffer = Data()
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
        Thread.detachNewThread { [weak self] in
            self?.readForever()
        }
    }

    private func readForever() {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }
    }

    func readLine(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                lock.unlock()
                return line
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }
}
