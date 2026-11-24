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
    var createModel: String?
    var createCWD: String?
    var createToolProfile: String?
    var createBriefID: String?
    var planUpdateID: String?
    var recheckMinutes: Double?
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
        if let createModel { object["create_model"] = createModel }
        if let createCWD { object["create_cwd"] = createCWD }
        if let createToolProfile { object["create_tool_profile"] = createToolProfile }
        if let createBriefID { object["create_brief_id"] = createBriefID }
        if let planUpdateID { object["plan_update_id"] = planUpdateID }
        if let recheckMinutes { object["recheck_minutes"] = recheckMinutes }
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
@discardableResult
private func sendEnvelope(_ envelope: BridgeEnvelope) -> Bool {
    guard let path = socketPath,
          let token = bridgeToken,
          let sessionID = consoleSessionID,
          !token.isEmpty,
          !sessionID.isEmpty,
          let data = envelope.encodedLine() else {
        return false
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
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
    guard connected else { return false }

    return data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

private let bridgeUnreachableMessage =
    "Console bridge unreachable: the request was not sent. Console may have quit or this session is not instrumented."

// MARK: - Hook Mode

/// Narrow decode of hook input: only fields Console needs. The raw payload is
/// discarded immediately after decoding; nothing sensitive is ever forwarded.
private struct HookInput: Decodable {
    let last_assistant_message: String?
    let new_cwd: String?

    enum CodingKeys: String, CodingKey {
        case last_assistant_message
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
    case "Stop":
        let reply = decoded?.last_assistant_message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = reply?.hasPrefix("API Error") == true ? "turn_failed" : "turn_completed"
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: outcome))
    case "NotificationIdlePrompt":
        sendEnvelope(BridgeEnvelope(kind: "lifecycle", lifecycleEvent: "idle_observed"))
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
        description: "List Console's open sessions (id, parent_id when the parent is listed, name, purpose, activity, attention, summary, bridge_status, artifacts) from the local sessions snapshot.",
        schema: [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "create_console_session",
        description: "Create a child session for an approved plan step. Choose a user-selectable Console purpose. Optional initial_prompt is the child's first task and its outcome is relayed to you. Blank sessions take no initial_prompt. At most four live children are allowed.",
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
                "model": ["type": "string", "minLength": 1, "maxLength": 120],
                "cwd": ["type": "string", "minLength": 1, "maxLength": 4096],
                "tool_profile": ["type": "string", "enum": ["full", "readOnlyPrep"]],
                "initial_prompt_file": ["type": "string", "description": "Local path to a UTF-8 task brief (up to 256 KiB). Use instead of initial_prompt."],
            ],
            "required": ["purpose"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "close_console_session",
        description: "Close a session by Console id. A child with a recorded result can be closed automatically; any other close needs user approval. Refuses the orchestrator.",
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
        description: "Send an approved plan directive to an existing session by Console session id. Console relays the outcome. Refuses the orchestrator and blank sessions.",
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
    MCPServerTool(
        name: "read_console_session_output",
        description: "Read-only: the last assistant replies of another Console session, from its Claude transcript. Use to see what a session actually did or is asking before proposing a step.",
        schema: [
            "type": "object",
            "properties": [
                "session_id": ["type": "string", "minLength": 1, "maxLength": 64],
                "messages": ["type": "integer", "minimum": 1, "maximum": 25],
                "since": ["type": "string", "description": "Opaque next_cursor from the previous read."],
            ],
            "required": ["session_id"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "cancel_console_directive",
        description: "Cancel directives you sent that are still held for a session (not yet typed). Use when the user changes direction after approving.",
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
        name: "get_plan",
        description: "Load the durable Orchestrator plan, current revision and numbered decisions.",
        schema: ["type": "object", "properties": [:], "additionalProperties": false]
    ),
    MCPServerTool(
        name: "update_plan",
        description: "Replace the plan using its current revision. Preserve stable step and decision IDs. A decision with no answer is open.",
        schema: [
            "type": "object",
            "properties": ["plan": [
                "type": "object",
                "required": ["revision", "goal", "approved", "steps", "decisions"],
                "properties": [
                    "revision": ["type": "integer", "minimum": 0],
                    "goal": ["type": "string"],
                    "approved": ["type": "boolean"],
                    "steps": ["type": "array", "items": [
                        "type": "object",
                        "required": ["id", "directive", "status"],
                        "properties": [
                            "id": ["type": "string"],
                            "owner_session": ["type": "string", "description": "Console UUID, omit until assigned."],
                            "owner_conversation": ["type": "string", "description": "Claude conversation UUID for restoring ownership."],
                            "directive": ["type": "string"],
                            "status": ["type": "string", "enum": ["pending", "held", "running", "blocked", "failed", "completed", "cancelled"]],
                        ],
                    ]],
                    "decisions": ["type": "array", "items": [
                        "type": "object",
                        "required": ["id", "question", "options"],
                        "properties": [
                            "id": ["type": "integer", "minimum": 1],
                            "question": ["type": "string"],
                            "options": ["type": "array", "items": ["type": "string"]],
                            "answer": ["type": "string"],
                            "presented": ["type": "boolean", "description": "Whether the numbered decision was already shown to the user."],
                            "session": ["type": "string", "description": "Console UUID of the session this decision is about. Its name becomes the card title."],
                            "title": ["type": "string", "description": "Card title when no session applies, such as a ticket key. One short line."],
                            "summary": ["type": "string", "description": "Two or three short sentences of current state the user needs to decide: what was done, what is true now, what the choice affects."],
                        ],
                    ]],
                ],
            ]],
            "required": ["plan"],
            "additionalProperties": false,
        ]
    ),
    MCPServerTool(
        name: "watch_console_session",
        description: "Wake the Orchestrator for turn outcomes, attention changes and exit of a live Claude peer.",
        schema: ["type": "object", "properties": ["session_id": ["type": "string"]], "required": ["session_id"]]
    ),
    MCPServerTool(
        name: "recheck_in",
        description: "Schedule a Console wake-up. A new recheck replaces the previous scheduled recheck.",
        schema: ["type": "object", "properties": ["minutes": ["type": "number", "minimum": 0.1, "maximum": 1440]], "required": ["minutes"]]
    ),
    MCPServerTool(
        name: "get_home_board",
        description: "Read-only: a fresh Console scan brief (sessions plus Home board Next up, In progress, Review queue) from Console's current data.",
        schema: [
            "type": "object",
            "properties": [:],
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
    case "read_console_session_output":
        outcome = handleReadConsoleSessionOutput(args)
    case "cancel_console_directive":
        outcome = handleCancelConsoleDirective(args)
    case "get_plan", "update_plan", "watch_console_session", "recheck_in":
        outcome = handleOrchestratorTool(toolName, args)
    case "get_home_board":
        outcome = handleGetHomeBoard()
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
private let mcpResultTimeoutSeconds: TimeInterval = 5.0
private let mcpCreateResultTimeoutSeconds: TimeInterval = 20.0

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
    // The envelope was delivered, so Console may still have applied it.
    return #"{"ok":null,"status":"unconfirmed","error":"Console did not confirm in time. The request may still have been applied: call list_console_sessions to check before retrying."}"#
}

private func handleOrchestratorTool(_ name: String, _ args: [String: Any]) -> Result<String, ToolFailure> {
    let requestID = UUID().uuidString
    var envelope = BridgeEnvelope(kind: name, requestID: requestID)
    var staged: URL?
    switch name {
    case "watch_console_session":
        guard let id = args["session_id"] as? String, UUID(uuidString: id) != nil else {
            return .failure(ToolFailure(message: "session_id must be a Console UUID"))
        }
        envelope.targetSessionID = id
    case "recheck_in":
        guard let minutes = args["minutes"] as? Double, (0.1...1440).contains(minutes) else {
            return .failure(ToolFailure(message: "minutes must be between 0.1 and 1440"))
        }
        envelope.recheckMinutes = minutes
    case "update_plan":
        guard let plan = args["plan"] as? [String: Any], let socketPath,
              let data = try? JSONSerialization.data(withJSONObject: plan), data.count <= 65536 else {
            return .failure(ToolFailure(message: "a plan object up to 64 KiB and an active bridge are required"))
        }
        let url = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            .appendingPathComponent("plan-update-\(requestID).json")
        do {
            try data.write(to: url, options: .atomic)
            staged = url
            envelope.planUpdateID = requestID
        } catch {
            return .failure(ToolFailure(message: "could not stage plan update"))
        }
    default:
        break
    }
    guard sendEnvelope(envelope) else {
        if let staged { try? FileManager.default.removeItem(at: staged) }
        return .failure(ToolFailure(message: bridgeUnreachableMessage))
    }
    let result = waitForMCPResult(requestID: requestID)
    if let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] {
        if let output = object["output"] as? String { return .success(output) }
        if object["ok"] as? Bool == false, let staged { try? FileManager.default.removeItem(at: staged) }
    }
    return .success(result)
}

private func refreshSessionsSnapshot() {
    guard mcpResultsDirectory != nil else { return }
    let requestID = UUID().uuidString
    guard sendEnvelope(BridgeEnvelope(kind: "refresh_sessions", requestID: requestID)) else { return }
    _ = waitForMCPResult(requestID: requestID, timeout: 1)
}

private func handleListConsoleSessions() -> Result<String, ToolFailure> {
    refreshSessionsSnapshot()
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

private func validText(_ value: String, maxLength: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maxLength
        && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.isDefaultIgnorableCodePoint }
}

private func localFileURL(_ path: String) -> URL? {
    guard validText(path, maxLength: 4096) else { return nil }
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
}

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
    let model = args["model"] as? String
    let cwd = args["cwd"] as? String
    let profile = args["tool_profile"] as? String
    if let model, !validText(model, maxLength: 120) {
        return .failure(ToolFailure(message: "invalid model"))
    }
    if let cwd, !validText(cwd, maxLength: 4096) {
        return .failure(ToolFailure(message: "invalid cwd"))
    }
    if let profile, !["full", "readOnlyPrep"].contains(profile) {
        return .failure(ToolFailure(message: "tool_profile must be full or readOnlyPrep"))
    }
    let requestID = UUID().uuidString
    var briefURL: URL?
    if let file = args["initial_prompt_file"] as? String {
        guard purpose != "blank", initialPrompt == nil, let socketPath else {
            return .failure(ToolFailure(message: "initial_prompt_file requires a connected Claude child and replaces initial_prompt"))
        }
        guard let source = localFileURL(file),
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...262144).contains(size),
              let handle = try? FileHandle(forReadingFrom: source) else {
            return .failure(ToolFailure(message: "initial_prompt_file must be a regular UTF-8 file up to 256 KiB"))
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262145), data.count <= 262144,
              let brief = String(data: data, encoding: .utf8),
              !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ToolFailure(message: "initial_prompt_file must contain a non-empty UTF-8 brief up to 256 KiB"))
        }
        let destination = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            .appendingPathComponent("child-brief-\(requestID).md")
        do {
            try data.write(to: destination, options: [.atomic])
            briefURL = destination
        } catch {
            return .failure(ToolFailure(message: "could not stage child brief"))
        }
    }
    let envelope = BridgeEnvelope(
        kind: "create_session",
        createPurpose: purpose,
        createName: name,
        createInitialPrompt: initialPrompt,
        createAgent: agent,
        createModel: model,
        createCWD: cwd,
        createToolProfile: profile,
        createBriefID: briefURL == nil ? nil : requestID,
        requestID: requestID
    )
    guard let encoded = envelope.encodedLine(), encoded.count <= 8192, sendEnvelope(envelope) else {
        if let briefURL { try? FileManager.default.removeItem(at: briefURL) }
        return .failure(ToolFailure(message: bridgeUnreachableMessage))
    }
    let result = waitForMCPResult(requestID: requestID, timeout: mcpCreateResultTimeoutSeconds)
    if let briefURL, let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
       object["ok"] as? Bool == false {
        try? FileManager.default.removeItem(at: briefURL)
    }
    return .success(result)
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
    guard sendEnvelope(BridgeEnvelope(
        kind: "close_session",
        targetSessionID: sessionID,
        requestID: requestID
    )) else { return .failure(ToolFailure(message: bridgeUnreachableMessage)) }
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
    guard sendEnvelope(BridgeEnvelope(
        kind: "prompt_session",
        targetSessionID: sessionID,
        promptText: prompt,
        requestID: requestID
    )) else { return .failure(ToolFailure(message: bridgeUnreachableMessage)) }
    return .success(waitForMCPResult(requestID: requestID))
}

private func validatedSessionIDArgument(_ args: [String: Any]) -> Result<String, ToolFailure> {
    guard let rawID = args["session_id"] as? String else {
        return .failure(ToolFailure(message: "session_id is required"))
    }
    let sessionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty, sessionID.count <= 64 else {
        return .failure(ToolFailure(message: "session_id must be 1-64 characters"))
    }
    return .success(sessionID)
}

private func handleCancelConsoleDirective(_ args: [String: Any]) -> Result<String, ToolFailure> {
    let sessionID: String
    switch validatedSessionIDArgument(args) {
    case .success(let id): sessionID = id
    case .failure(let failure): return .failure(failure)
    }
    let requestID = UUID().uuidString
    guard sendEnvelope(BridgeEnvelope(
        kind: "cancel_directive",
        targetSessionID: sessionID,
        requestID: requestID
    )) else { return .failure(ToolFailure(message: bridgeUnreachableMessage)) }
    return .success(waitForMCPResult(requestID: requestID))
}

private func handleGetHomeBoard() -> Result<String, ToolFailure> {
    let requestID = UUID().uuidString
    guard sendEnvelope(BridgeEnvelope(kind: "home_board", requestID: requestID)) else {
        return .failure(ToolFailure(message: bridgeUnreachableMessage))
    }
    let result = waitForMCPResult(requestID: requestID)
    // Return the brief as plain text when Console supplied it.
    if let data = result.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let output = object["output"] as? String {
        return .success(output)
    }
    return .success(result)
}

/// Reads the target's transcript directly: the sessions snapshot gives its
/// Claude session id, and transcripts live under ~/.claude/projects.
private func handleReadConsoleSessionOutput(_ args: [String: Any]) -> Result<String, ToolFailure> {
    let sessionID: String
    switch validatedSessionIDArgument(args) {
    case .success(let id): sessionID = id
    case .failure(let failure): return .failure(failure)
    }
    let count = min(max((args["messages"] as? Int) ?? 5, 1), 25)
    let since: UInt64?
    if let cursor = args["since"] as? String {
        guard let offset = UInt64(cursor) else {
            return .failure(ToolFailure(message: "since must be a next_cursor from this session"))
        }
        since = offset
    } else {
        since = nil
    }
    refreshSessionsSnapshot()
    guard let path = sessionsSnapshotPath, !path.isEmpty,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return .failure(ToolFailure(message: "sessions snapshot unavailable"))
    }
    guard let row = rows.first(where: {
        ($0["id"] as? String)?.caseInsensitiveCompare(sessionID) == .orderedSame
    }) else {
        return .failure(ToolFailure(message: "session not found"))
    }
    var output = row
    let transcript = (row["claude_session_id"] as? String).flatMap(findTranscript(claudeSessionID:))
    let page = transcript.flatMap { assistantReplyPage(at: $0, count: count, since: since) }
    output["messages"] = page?.messages ?? []
    output["next_cursor"] = String(page?.next ?? since ?? 0)
    output["has_more"] = page?.hasMore ?? false
    if page?.reset == true { output["cursor_reset"] = true }
    if transcript == nil { output["transcript_pending"] = true }
    guard let result = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
        return .failure(ToolFailure(message: "could not encode session output"))
    }
    return .success(String(decoding: result, as: UTF8.self))
}

private func findTranscript(claudeSessionID: String) -> URL? {
    let config = environmentValue("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    let root = config.appendingPathComponent("projects", isDirectory: true)
    guard let projects = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return nil }
    for project in projects {
        for name in [claudeSessionID, claudeSessionID.lowercased(), claudeSessionID.uppercased()] {
            let candidate = project.appendingPathComponent("\(name).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
    }
    return nil
}

/// Offset cursors advance through complete JSONL lines. Initial reads take
/// the newest replies; reads with a cursor page forward without skipping.
private func assistantReplyPage(at url: URL, count: Int, since: UInt64?) ->
    (messages: [[String: Any]], next: UInt64, hasMore: Bool, reset: Bool)? {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let size = try? handle.seekToEnd() else { return nil }
    defer { try? handle.close() }
    let window: UInt64 = 512 * 1024
    let reset = since.map { $0 > size } ?? false
    let cursor = reset ? nil : since
    var offset = cursor ?? (size > window ? size - window : 0)
    guard (try? handle.seek(toOffset: offset)) != nil,
          let data = try? handle.read(upToCount: Int(min(size - offset, window))) else {
        return ([], offset, false, reset)
    }
    var messages: [[String: Any]] = []
    var start = data.startIndex
    while start < data.endIndex, let newline = data[start...].firstIndex(of: 0x0a) {
        let skipPartialHead = cursor == nil && start == data.startIndex && offset > 0
        let line = data[start..<newline]
        offset += UInt64(newline + 1 - start)
        start = newline + 1
        guard !skipPartialHead,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { continue }
        let reply = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { continue }
        var entry: [String: Any] = ["text": String(reply.prefix(4000))]
        entry["timestamp"] = object["timestamp"] ?? NSNull()
        messages.append(entry)
        if cursor != nil, messages.count == count { break }
    }
    if start == data.startIndex, size - offset > window {
        // One oversized record can span the entire page. Resync at the
        // bounded tail rather than returning the same cursor indefinitely.
        if let tail = assistantReplyPage(at: url, count: count, since: nil) {
            return (tail.messages, tail.next, tail.hasMore, true)
        }
    }
    let hasMore = data[start...].contains(0x0a) || size - offset > UInt64(data.count - start)
    return (Array(messages.suffix(count)), offset, hasMore, reset)
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
