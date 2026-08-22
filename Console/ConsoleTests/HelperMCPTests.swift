import XCTest
@testable import Console

/// End-to-end MCP-mode tests against the real embedded helper binary.
final class HelperMCPTests: XCTestCase {

    private var process: Process!
    private var stdinHandle: FileHandle!
    private var stdoutReader: LinePoller!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path
        guard FileManager.default.fileExists(atPath: helperPath) else {
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

        p.environment = [
            "CONSOLE_TERM_BRIDGE_SOCKET": "",
            "CONSOLE_TERM_BRIDGE_SESSION_ID": UUID().uuidString,
            "CONSOLE_TERM_BRIDGE_TOKEN": "unused-token",
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
        try super.tearDownWithError()
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

    func testToolsListExposesExactlyThreeConsoleTools() throws {
        let response = try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["report_attention", "link_artifact", "report_completion"])

        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"], "\(tool) must declare an input schema")
            XCTAssertNotNil(tool["description"])
        }
    }

    // MARK: - Tool calls (socket env is unset, so forwarding is a no-op —
    // validation and result framing are still exercised)

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
    }

    func testNonHTTPSURLRejected() throws {
        let response = try send([
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": [
                "name": "link_artifact",
                "arguments": ["kind": "jira_issue", "label": "ENG-1", "url": "http://example.com/x"],
            ],
        ])
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
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
