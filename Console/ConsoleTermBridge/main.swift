import Foundation

// ConsoleTermBridge — embedded Console helper.
//
// Two modes:
//   ConsoleTermBridge hook <event-name>   Forward one reduced lifecycle event to Console.
//   ConsoleTermBridge mcp                 Serve the Console MCP tools over stdio.
//
// Configuration arrives through the environment of the Claude process:
//   CONSOLE_TERM_BRIDGE_HELPER       Absolute path to this helper.
//   CONSOLE_TERM_BRIDGE_SOCKET       Unix-domain socket path owned by Console.
//   CONSOLE_TERM_BRIDGE_SESSION_ID   Console session UUID.
//   CONSOLE_TERM_BRIDGE_TOKEN        Random per-session token.
//
// Hook mode never prints and always exits 0 so it can never block or change
// Claude behavior. MCP mode writes only newline-delimited JSON-RPC to stdout.

private let protocolVersion = 1

// MARK: - Environment

private func environmentValue(_ key: String) -> String? {
    let value = ProcessInfo.processInfo.environment[key]
    return (value?.isEmpty == false) ? value : nil
}

private var socketPath: String? { environmentValue("CONSOLE_TERM_BRIDGE_SOCKET") }
private var consoleSessionID: String? { environmentValue("CONSOLE_TERM_BRIDGE_SESSION_ID") }
private var bridgeToken: String? { environmentValue("CONSOLE_TERM_BRIDGE_TOKEN") }

// MARK: - Envelope

/// Wire envelope matching Console's `BridgeEnvelope`.
struct BridgeEnvelope {
    var kind: String
    var lifecycleEvent: String?
    var attentionCategory: String?
    var attentionMessage: String?
    var artifactKind: String?
    var artifactLabel: String?
    var artifactURL: String?
    var completionOutcome: String?
    var completionSummary: String?
    var cwdDirectory: String?
    var createPurpose: String?
    var createName: String?
    var createInitialPrompt: String?
    var createAgent: String?
    var targetSessionID: String?
    var promptText: String?
    var requestID: String?

    func encodedLine() -> Data? {
        var object: [String: Any] = [
            "protocol_version": protocolVersion,
            "session_id": consoleSessionID ?? "",
            "token": bridgeToken ?? "",
            "event_id": UUID().uuidString,
            "kind": kind,
        ]
        if let lifecycleEvent { object["lifecycle_event"] = lifecycleEvent }
        if let attentionCategory { object["attention_category"] = attentionCategory }
        if let attentionMessage { object["attention_message"] = attentionMessage }
        if let artifactKind { object["artifact_kind"] = artifactKind }
        if let artifactLabel { object["artifact_label"] = artifactLabel }
        if let artifactURL { object["artifact_url"] = artifactURL }
        if let completionOutcome { object["completion_outcome"] = completionOutcome }
        if let completionSummary { object["completion_summary"] = completionSummary }
        if let cwdDirectory { object["cwd_directory"] = cwdDirectory }
        if let createPurpose { object["create_purpose"] = createPurpose }
        if let createName { object["create_name"] = createName }
        if let createInitialPrompt { object["create_initial_prompt"] = createInitialPrompt }
        if let createAgent { object["create_agent"] = createAgent }
        if let targetSessionID { object["target_session_id"] = targetSessionID }
        if let promptText { object["prompt_text"] = promptText }
        if let requestID { object["request_id"] = requestID }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        var line = data
        line.append(UInt8(ascii: "\n"))
        return line
    }
}

/// Sends one envelope line to Console. All failures are silent.
private func sendEnvelope(_ envelope: BridgeEnvelope) {
    guard let path = socketPath,
          let token = bridgeToken,
          let sessionID = consoleSessionID,
          !token.isEmpty,
          !sessionID.isEmpty,
          let data = envelope.encodedLine() else {
        return
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
    let connected: Bool = pathBytes.withUnsafeBufferPointer { bytes in
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            let destinationPointer = destination.baseAddress!.assumingMemoryBound(to: CChar.self)
            _ = strlcpy(destinationPointer, bytes.baseAddress!, destination.count)
        }
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
    guard connected else { return }

    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

// MARK: - Hook Mode

/// Narrow decode of hook input: only fields Console needs. The raw payload is
/// discarded immediately after decoding; nothing sensitive is ever forwarded.
private struct HookInput: Decodable {
    let notification_type: String?
    let new_cwd: String?

    enum CodingKeys: String, CodingKey {
        case notification_type = "notification_type"
        case new_cwd = "new_cwd"
    }
}

func runHookMode(eventName: String) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let decoded = try? JSONDecoder().decode(HookInput.self, from: input)

    switch eventName {
    case "SessionStart":
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: "session_started"))
    case "UserPromptSubmit":
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: "prompt_submitted"))
    case "Stop", "NotificationIdlePrompt":
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: "turn_completed"))
    case "StopFailure":
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: "turn_failed"))
    case "SessionEnd":
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: "session_ended"))
    case "PermissionRequest":
        sendEnvelope(BridgeEnvelope(
            kind: "attention",
            lifecycleEvent: nil,
            attentionCategory: "permission",
            attentionMessage: nil
        ))
    case "AskUserQuestion":
        sendEnvelope(BridgeEnvelope(
            kind: "attention",
            lifecycleEvent: nil,
            attentionCategory: "question",
            attentionMessage: nil
        ))
    case "CwdChanged":
        guard let directory = decoded?.new_cwd, !directory.isEmpty else { return }
        sendEnvelope(BridgeEnvelope(kind: "cwd", lifecycleEvent: nil, cwdDirectory: directory))
    default:
        // Unknown or unmatched events carry no state.
        break
    }

    // Raw stdin data goes out of scope here; nothing is retained or logged.
    _ = input
}

// MARK: - MCP Mode

private struct ToolFailure: Error {
    let message: String
}

private struct MCPServerTool {
    let name: String
    let description: String
    let schema: [String: Any]
}

private let consoleTools: [MCPServerTool] = [
    MCPServerTool(
        name: "report_attention",
        description: "Report an attention state to Console so the user notices. Use for questions you need answered, blocked work, or work that needs review.",
        schema: [
            "type": "object",
            "properties": [
                "category": ["type": "string", "enum": ["question", "blocked", "needs_review"]],
                "message": ["type": "string", "minLength": 1, "maxLength": 240],
            ],
            "required": ["category", "message"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "link_artifact",
        description: "Link an informational artifact chip (JIRA issue or GitLab merge request) to the Console session. Never fetches the URL. A jira_issue URL must be a JIRA issue URL, and a gitlab_merge_request URL must be a GitLab merge request URL.",
        schema: [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["jira_issue", "gitlab_merge_request"]],
                "label": ["type": "string", "minLength": 1, "maxLength": 80],
                "url": ["type": "string", "maxLength": 2048],
            ],
            "required": ["kind", "label"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "report_completion",
        description: "Report task completion to Console when a summary is valuable to the user.",
        schema: [
            "type": "object",
            "properties": [
                "outcome": ["type": "string", "enum": ["completed", "blocked", "needs_review"]],
                "summary": ["type": "string", "minLength": 1, "maxLength": 400],
            ],
            "required": ["outcome", "summary"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "list_console_sessions",
        description: "List Console's open sessions (id, name, purpose, activity, attention, summary, bridge_status, artifacts) from the local sessions snapshot.",
        schema: [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "create_console_session",
        description: "Ask Console to create a visible session in the Sessions list. Prefer after user approval. Purpose must be a user-selectable Console purpose (not orchestrator). Optional initial_prompt is queued after create.",
        schema: [
            "type": "object",
            "properties": [
                "purpose": [
                    "type": "string",
                    "enum": ["blank", "newTicket", "existingTicket", "review", "general"],
                ],
                "name": ["type": "string", "minLength": 1, "maxLength": 80],
                "initial_prompt": ["type": "string", "minLength": 1, "maxLength": 1500],
                "agent": ["type": "string", "minLength": 1, "maxLength": 80],
            ],
            "required": ["purpose"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "close_console_session",
        description: "Ask Console to terminate and remove another visible session by Console session id. Refuses the orchestrator. Prefer after user approval.",
        schema: [
            "type": "object",
            "properties": [
                "session_id": ["type": "string", "minLength": 1, "maxLength": 64],
            ],
            "required": ["session_id"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "prompt_console_session",
        description: "Queue a directive prompt into another Console session after user approval. Prefer this over SendMessage for actionable direction. Refuses the orchestrator.",
        schema: [
            "type": "object",
            "properties": [
                "session_id": ["type": "string", "minLength": 1, "maxLength": 64],
                "prompt": ["type": "string", "minLength": 1, "maxLength": 1500],
            ],
            "required": ["session_id", "prompt"],
            "additionalProperties": false,
        ]
    ),
]

private func runMCPMode() {
    let stdout = FileHandle.standardOutput
    let stdinHandle = FileHandle.standardInput
    var pending = Data()

    while true {
        guard let lineData = readLineData(from: stdinHandle, buffer: &pending) else { break }
        if lineData.isEmpty { continue }

        guard let parsed = try? JSONSerialization.jsonObject(with: lineData),
              let request = parsed as? [String: Any] else {
            writeJSON(
                [
                    "jsonrpc": "2.0",
                    "id": NSNull(),
                    "error": ["code": -32700, "message": "Parse error"],
                ],
                to: stdout
            )
            continue
        }

        let method = request["method"] as? String
        let hasID = request["id"] != nil && !(request["id"] is NSNull)

        switch method {
        case "initialize" where hasID:
            let requestedVersion = (request["params"] as? [String: Any])?["protocolVersion"]
            writeJSON(
                [
                    "jsonrpc": "2.0",
                    "id": request["id"]!,
                    "result": [
                        "protocolVersion": requestedVersion ?? "2025-06-18",
                        "capabilities": ["tools": [:]],
                        "serverInfo": [
                            "name": "console-bridge",
                            "version": "1.0.0",
                        ],
                    ],
                ],
                to: stdout
            )
        case "notifications/initialized":
            break
        case "ping" where hasID:
            writeJSON(["jsonrpc": "2.0", "id": request["id"]!, "result": [:]], to: stdout)
        case "tools/list" where hasID:
            writeJSON(
                [
                    "jsonrpc": "2.0",
                    "id": request["id"]!,
                    "result": [
                        "tools": consoleTools.map { tool in
                            [
                                "name": tool.name,
                                "description": tool.description,
                                "inputSchema": tool.schema,
                            ]
                        },
                    ],
                ],
                to: stdout
            )
        case "tools/call" where hasID:
            handleToolsCall(request: request, stdout: stdout)
        default:
            if hasID {
                writeJSON(
                    [
                        "jsonrpc": "2.0",
                        "id": request["id"]!,
                        "error": ["code": -32601, "message": "Method not found"],
                    ],
                    to: stdout
                )
            }
        }
    }
}

private func handleToolsCall(request: [String: Any], stdout: FileHandle) {
    let params = request["params"] as? [String: Any] ?? [:]
    let toolName = params["name"] as? String ?? ""
    let args = params["arguments"] as? [String: Any] ?? [:]

    let outcome: Result<String, ToolFailure>
    switch toolName {
    case "report_attention":
        outcome = handleReportAttention(args)
    case "link_artifact":
        outcome = handleLinkArtifact(args)
    case "report_completion":
        outcome = handleReportCompletion(args)
    case "list_console_sessions":
        outcome = handleListConsoleSessions()
    case "create_console_session":
        outcome = handleCreateConsoleSession(args)
    case "close_console_session":
        outcome = handleCloseConsoleSession(args)
    case "prompt_console_session":
        outcome = handlePromptConsoleSession(args)
    default:
        outcome = .failure(ToolFailure(message: "Unknown tool: \(toolName)"))
    }

    switch outcome {
    case .success(let text):
        writeJSON(
            [
                "jsonrpc": "2.0",
                "id": request["id"]!,
                "result": [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ],
            ],
            to: stdout
        )
    case .failure(let failure):
        writeJSON(
            [
                "jsonrpc": "2.0",
                "id": request["id"]!,
                "result": [
                    "content": [["type": "text", "text": failure.message]],
                    "isError": true,
                ],
            ],
            to: stdout
        )
    }
}

private func handleReportAttention(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let category = args["category"] as? String else {
        return .failure(ToolFailure(message: "category is required"))
    }
    guard ["question", "blocked", "needs_review"].contains(category) else {
        return .failure(ToolFailure(message: "category must be one of question, blocked, needs_review"))
    }
    guard let rawMessage = args["message"] as? String else {
        return .failure(ToolFailure(message: "message is required"))
    }
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        return .failure(ToolFailure(message: "message must not be empty"))
    }
    guard message.count <= 240 else {
        return .failure(ToolFailure(message: "message must be at most 240 characters"))
    }
    sendEnvelope(BridgeEnvelope(
        kind: "attention",
        lifecycleEvent: nil,
        attentionCategory: category,
        attentionMessage: message
    ))
    return .success("ok")
}

private func isJiraIssueKey(_ candidate: String) -> Bool {
    candidate.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil
}

/// Same acceptance rules as Console's `JiraSourceContext.parseIssueKey` and
/// `GitLabSourceContext.parseMergeRequest`. The helper cannot import those types.
private func artifactURLMatchesKind(_ url: URL, kind: String) -> Bool {
    switch kind {
    case "jira_issue":
        let pathComponents = url.path.split(separator: "/").map(String.init)
        if let index = pathComponents.firstIndex(of: "browse"), index + 1 < pathComponents.count,
           isJiraIssueKey(pathComponents[index + 1]) {
            return true
        }
        if let index = pathComponents.firstIndex(of: "issues"), index + 1 < pathComponents.count,
           isJiraIssueKey(pathComponents[index + 1]) {
            return true
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "selectedIssue" })?.value,
           isJiraIssueKey(value) {
            return true
        }
        return false
    case "gitlab_merge_request":
        guard url.host != nil,
              let match = url.path.range(of: #"/-/merge_requests/\d+"#, options: .regularExpression) else {
            return false
        }
        let projectPath = String(url.path[..<match.lowerBound])
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).count >= 2
    default:
        return false
    }
}

private func handleLinkArtifact(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let kind = args["kind"] as? String else {
        return .failure(ToolFailure(message: "kind is required"))
    }
    guard ["jira_issue", "gitlab_merge_request"].contains(kind) else {
        return .failure(ToolFailure(message: "kind must be jira_issue or gitlab_merge_request"))
    }
    guard let rawLabel = args["label"] as? String else {
        return .failure(ToolFailure(message: "label is required"))
    }
    let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else {
        return .failure(ToolFailure(message: "label must not be empty"))
    }
    guard label.count <= 80 else {
        return .failure(ToolFailure(message: "label must be at most 80 characters"))
    }
    var urlString: String?
    if let providedURL = args["url"] as? String, !providedURL.isEmpty {
        guard providedURL.count <= 2048 else {
            return .failure(ToolFailure(message: "url must be at most 2048 characters"))
        }
        guard let url = URL(string: providedURL), url.scheme?.lowercased() == "https" else {
            return .failure(ToolFailure(message: "url must be an HTTPS URL"))
        }
        guard artifactURLMatchesKind(url, kind: kind) else {
            let expected = kind == "jira_issue" ? "a JIRA issue URL" : "a GitLab merge request URL"
            return .failure(ToolFailure(message: "url must be \(expected)"))
        }
        urlString = providedURL
    }
    sendEnvelope(BridgeEnvelope(
        kind: "artifact",
        lifecycleEvent: nil,
        artifactKind: kind,
        artifactLabel: label,
        artifactURL: urlString
    ))
    return .success("ok")
}

private func handleReportCompletion(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let outcome = args["outcome"] as? String else {
        return .failure(ToolFailure(message: "outcome is required"))
    }
    guard ["completed", "blocked", "needs_review"].contains(outcome) else {
        return .failure(ToolFailure(message: "outcome must be one of completed, blocked, needs_review"))
    }
    guard let rawSummary = args["summary"] as? String else {
        return .failure(ToolFailure(message: "summary is required"))
    }
    let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summary.isEmpty else {
        return .failure(ToolFailure(message: "summary must not be empty"))
    }
    guard summary.count <= 400 else {
        return .failure(ToolFailure(message: "summary must be at most 400 characters"))
    }
    sendEnvelope(BridgeEnvelope(
        kind: "completion",
        lifecycleEvent: nil,
        completionOutcome: outcome,
        completionSummary: summary
    ))
    return .success("ok")
}

private var sessionsSnapshotPath: String? { environmentValue("CONSOLE_SESSIONS_SNAPSHOT") }
private var mcpResultsDirectory: String? { environmentValue("CONSOLE_MCP_RESULTS_DIR") }

/// Close/prompt only write a result file; create also materializes a plugin and
/// launches Claude on the main queue, so it needs a longer bound.
private let mcpResultTimeoutSeconds: TimeInterval = 2.0
private let mcpCreateResultTimeoutSeconds: TimeInterval = 8.0

private func waitForMCPResult(
    requestID: String,
    timeout: TimeInterval = mcpResultTimeoutSeconds
) -> String {
    guard let directory = mcpResultsDirectory, !directory.isEmpty else {
        return #"{"ok":false,"error":"mcp results directory unavailable"}"#
    }
    let path = URL(fileURLWithPath: directory).appendingPathComponent("\(requestID).json").path
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return text
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return #"{"ok":false,"error":"timeout waiting for Console"}"#
}

private func handleListConsoleSessions() -> Result<String, ToolFailure> {
    guard let path = sessionsSnapshotPath, !path.isEmpty else {
        return .failure(ToolFailure(message: "sessions snapshot unavailable"))
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let text = String(data: data, encoding: .utf8),
          !text.isEmpty else {
        return .success("[]")
    }
    return .success(text)
}

private let creatablePurposes: Set<String> = [
    "blank", "newTicket", "existingTicket", "review", "general",
]

private func handleCreateConsoleSession(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let purpose = args["purpose"] as? String else {
        return .failure(ToolFailure(message: "purpose is required"))
    }
    guard creatablePurposes.contains(purpose) else {
        return .failure(ToolFailure(message: "purpose must be one of blank, newTicket, existingTicket, review, general"))
    }
    var name: String?
    if let rawName = args["name"] as? String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ToolFailure(message: "name must not be empty"))
        }
        guard trimmed.count <= 80 else {
            return .failure(ToolFailure(message: "name must be at most 80 characters"))
        }
        name = trimmed
    }
    var initialPrompt: String?
    if let rawPrompt = args["initial_prompt"] as? String {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ToolFailure(message: "initial_prompt must not be empty"))
        }
        guard trimmed.count <= 1500 else {
            return .failure(ToolFailure(message: "initial_prompt must be at most 1500 characters"))
        }
        initialPrompt = trimmed
    }
    var agent: String?
    if let rawAgent = args["agent"] as? String {
        let trimmed = rawAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ToolFailure(message: "agent must not be empty"))
        }
        guard trimmed.count <= 80 else {
            return .failure(ToolFailure(message: "agent must be at most 80 characters"))
        }
        agent = trimmed
    }
    let requestID = UUID().uuidString
    sendEnvelope(BridgeEnvelope(
        kind: "create_session",
        createPurpose: purpose,
        createName: name,
        createInitialPrompt: initialPrompt,
        createAgent: agent,
        requestID: requestID
    ))
    return .success(waitForMCPResult(requestID: requestID, timeout: mcpCreateResultTimeoutSeconds))
}

private func handleCloseConsoleSession(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let rawID = args["session_id"] as? String else {
        return .failure(ToolFailure(message: "session_id is required"))
    }
    let sessionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else {
        return .failure(ToolFailure(message: "session_id must not be empty"))
    }
    guard sessionID.count <= 64 else {
        return .failure(ToolFailure(message: "session_id must be at most 64 characters"))
    }
    if let selfID = consoleSessionID, sessionID.caseInsensitiveCompare(selfID) == .orderedSame {
        return .failure(ToolFailure(message: "refused: cannot close the orchestrator session"))
    }
    let requestID = UUID().uuidString
    sendEnvelope(BridgeEnvelope(
        kind: "close_session",
        targetSessionID: sessionID,
        requestID: requestID
    ))
    return .success(waitForMCPResult(requestID: requestID))
}

private func handlePromptConsoleSession(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let rawID = args["session_id"] as? String else {
        return .failure(ToolFailure(message: "session_id is required"))
    }
    let sessionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else {
        return .failure(ToolFailure(message: "session_id must not be empty"))
    }
    guard sessionID.count <= 64 else {
        return .failure(ToolFailure(message: "session_id must be at most 64 characters"))
    }
    if let selfID = consoleSessionID, sessionID.caseInsensitiveCompare(selfID) == .orderedSame {
        return .failure(ToolFailure(message: "refused: cannot prompt the orchestrator session"))
    }
    guard let rawPrompt = args["prompt"] as? String else {
        return .failure(ToolFailure(message: "prompt is required"))
    }
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
        return .failure(ToolFailure(message: "prompt must not be empty"))
    }
    guard prompt.count <= 1500 else {
        return .failure(ToolFailure(message: "prompt must be at most 1500 characters"))
    }
    let requestID = UUID().uuidString
    sendEnvelope(BridgeEnvelope(
        kind: "prompt_session",
        targetSessionID: sessionID,
        promptText: prompt,
        requestID: requestID
    ))
    return .success(waitForMCPResult(requestID: requestID))
}

// MARK: - Stdio helpers

/// Reads one newline-delimited message, preserving any buffered remainder so
/// batched writes are never dropped.
private func readLineData(from handle: FileHandle, buffer: inout Data) -> Data? {
    while true {
        if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            return line
        }
        if buffer.count > 1024 * 1024 {
            return nil
        }
        let chunk = handle.availableData
        if chunk.isEmpty {
            // EOF: flush a trailing unterminated line, then report EOF next time.
            if buffer.isEmpty { return nil }
            let line = buffer
            buffer.removeAll(keepingCapacity: false)
            return line
        }
        buffer.append(chunk)
    }
}

private func writeJSON(_ object: [String: Any], to handle: FileHandle) {
    guard JSONSerialization.isValidJSONObject(object),
          var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return
    }
    data.append(UInt8(ascii: "\n"))
    handle.write(data)
}

// MARK: - Entry

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    exit(EXIT_SUCCESS)
}

switch arguments[1] {
case "hook":
    guard arguments.count >= 3 else { exit(EXIT_SUCCESS) }
    runHookMode(eventName: arguments[2])
case "mcp":
    runMCPMode()
default:
    break
}
exit(EXIT_SUCCESS)
