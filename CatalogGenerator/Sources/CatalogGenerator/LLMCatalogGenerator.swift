import Foundation

// MARK: - Configuration

enum LLMProvider: String {
    case openAI, claude, gemini
}

struct LLMConfig {
    let provider: LLMProvider
    let apiKey: String
    let model: String
    let endpointURL: String

    static func openAI(apiKey: String, model: String = "gpt-4o") -> LLMConfig {
        LLMConfig(
            provider: .openAI,
            apiKey: apiKey,
            model: model,
            endpointURL: "https://api.openai.com/v1/chat/completions"
        )
    }

    static func claude(apiKey: String, model: String = "claude-sonnet-4-20250514") -> LLMConfig {
        LLMConfig(
            provider: .claude,
            apiKey: apiKey,
            model: model,
            endpointURL: "https://api.anthropic.com/v1/messages"
        )
    }

    static func gemini(apiKey: String, model: String = "gemini-2.0-flash") -> LLMConfig {
        LLMConfig(
            provider: .gemini,
            apiKey: apiKey,
            model: model,
            endpointURL: "https://generativelanguage.googleapis.com/v1beta/models"
        )
    }
}

// MARK: - Errors

enum CatalogGeneratorError: Error, LocalizedError {
    case invalidResponse
    case apiError(String)
    case networkError(Error)
    case parsingFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid LLM response"
        case .apiError(let msg): return "API error: \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .parsingFailed(let msg): return "Parsing failed: \(msg)"
        case .validationFailed(let msg): return "Validation failed: \(msg)"
        }
    }
}

// MARK: - Generation Result

struct GenerationResult {
    let appName: String
    let bundleID: String
    let entry: [String: Any]
    let rawResponse: String
}

struct BatchResult {
    let succeeded: [GenerationResult]
    let failed: [(appName: String, error: Error)]
    let totalApps: Int

    var successRate: Double {
        guard totalApps > 0 else { return 0 }
        return Double(succeeded.count) / Double(totalApps)
    }
}

// MARK: - LLM Catalog Generator

class LLMCatalogGenerator {
    private let config: LLMConfig
    private let verbose: Bool
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval = 1.0

    init(config: LLMConfig, verbose: Bool = false) {
        self.config = config
        self.verbose = verbose
    }

    // MARK: - Single Entry Generation

    func generateCatalogEntry(from appData: RawAppData) async throws -> GenerationResult {
        let appName = appData.displayName ?? "Unknown"
        let bundleID = appData.bundleID ?? "unknown"

        if verbose { print("  Generating catalog entry for \(appName)...") }

        let prompt = buildPrompt(for: appData)
        let response = try await sendRequest(systemPrompt: systemPrompt, userMessage: prompt)

        if verbose { print("  Received LLM response (\(response.count) chars)") }

        let entry = try parseResponse(response, appName: appName)
        try validateEntry(entry, appName: appName)

        return GenerationResult(
            appName: appName,
            bundleID: bundleID,
            entry: entry,
            rawResponse: response
        )
    }

    // MARK: - Batch Processing

    func generateBatch(
        from apps: [RawAppData],
        continueOnError: Bool = true
    ) async -> BatchResult {
        var succeeded: [GenerationResult] = []
        var failed: [(appName: String, error: Error)] = []

        for (index, app) in apps.enumerated() {
            let name = app.displayName ?? "Unknown"
            if verbose {
                print("[\(index + 1)/\(apps.count)] Processing \(name)...")
            }

            do {
                let result = try await generateCatalogEntry(from: app)
                succeeded.append(result)
                if verbose { print("  ✓ \(name) generated successfully") }
            } catch {
                failed.append((appName: name, error: error))
                if verbose { print("  ✗ \(name) failed: \(error.localizedDescription)") }
                if !continueOnError { break }
            }
        }

        return BatchResult(
            succeeded: succeeded,
            failed: failed,
            totalApps: apps.count
        )
    }

    // MARK: - Assemble Catalog JSON

    func assembleCatalog(from results: [GenerationResult], version: String = "1.1.0") -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "version": version,
            "lastUpdated": formatter.string(from: Date()),
            "macOSVersions": ["15.0"],
            "apps": results.map(\.entry)
        ]
    }

    func writeCatalog(_ catalog: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: catalog,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Merges this run's entries into an existing catalog: regenerated apps
    /// replace their previous entry, all other apps are retained. This keeps a
    /// partial run (`--app-id`, or one with failures) from clobbering the full
    /// catalog with only this run's successes. Regenerating from scratch still
    /// removes dropped apps — write to a fresh output for that.
    func merging(_ catalog: [String: Any], into base: [String: Any]) -> [String: Any] {
        guard let newEntries = catalog["apps"] as? [[String: Any]],
              let baseEntries = base["apps"] as? [[String: Any]] else {
            return catalog
        }

        let regeneratedIDs = Set(newEntries.compactMap { $0["bundleID"] as? String })
        let retained = baseEntries.filter { entry in
            !regeneratedIDs.contains(entry["bundleID"] as? String ?? "")
        }

        var merged = base
        merged["version"] = catalog["version"] ?? base["version"]
        merged["lastUpdated"] = catalog["lastUpdated"] ?? base["lastUpdated"]
        merged["macOSVersions"] = catalog["macOSVersions"] ?? base["macOSVersions"]
        merged["apps"] = retained + newEntries
        return merged
    }

    /// Loads the existing output file for merging, if present and parseable.
    func existingCatalog(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["apps"] is [[String: Any]] else {
            return nil
        }
        return json
    }

    // MARK: - Prompt Construction

    private var systemPrompt: String {
        """
        You are a macOS automation expert generating structured catalog entries \
        for the Console voice command app. Your output must be valid JSON \
        matching the exact schema specified. Focus on reliability, common use \
        cases, and accurate timing estimates. Prioritize automation methods: \
        App Intents > AppleScript > Shell commands.
        """
    }

    private func buildPrompt(for app: RawAppData) -> String {
        var prompt = """
        Generate a catalog entry for this macOS application.

        APP INFO:
        - Name: \(app.displayName ?? "Unknown")
        - Bundle ID: \(app.bundleID ?? "unknown")
        - Version: \(app.version ?? "unknown")

        """

        if let parsed = app.parsedDictionary {
            prompt += "APPLESCRIPT DICTIONARY:\n"
            for suite in parsed.suites {
                prompt += "  Suite: \(suite.name)\n"
                for cmd in suite.commands {
                    let params = cmd.parameters.map {
                        "\($0.name):\($0.type)\($0.isOptional ? "?" : "")"
                    }.joined(separator: ", ")
                    let dp = cmd.directParameter.map { " direct:\($0.type)" } ?? ""
                    prompt += "    Command: \(cmd.name)\(dp) [\(params)]\n"
                    if let desc = cmd.description {
                        prompt += "      \(desc)\n"
                    }
                }
                for cls in suite.classes {
                    let props = cls.properties.map {
                        "\($0.name):\($0.type)(\($0.access))"
                    }.joined(separator: ", ")
                    prompt += "    Class: \(cls.name) [\(props)]\n"
                }
            }
            prompt += "\n"
        } else if app.hasAppleScriptDictionary {
            prompt += "APPLESCRIPT: Has dictionary (not parsed)\n\n"
        }

        if app.hasAppIntentsMetadata {
            prompt += "APP INTENTS METADATA KEYS: \(app.appIntentsMetadataKeys.joined(separator: ", "))\n\n"
        }

        if !app.shortcutsActions.isEmpty {
            prompt += "SHORTCUTS ACTIONS:\n"
            for action in app.shortcutsActions {
                prompt += "  - \(action.title): \(action.description ?? "no description")\n"
            }
            prompt += "\n"
        }

        prompt += """
        OUTPUT FORMAT — return ONLY valid JSON matching this exact schema:
        {
          "name": "<app display name>",
          "bundleID": "<bundle identifier>",
          "minMacOSVersion": "<minimum macOS version, e.g. 13.0>",
          "appIntents": [
            {
              "intentName": "<intent class name>",
              "intentDescription": "<what it does>",
              "parameters": [
                {
                  "name": "<param name>",
                  "type": "<String|Int|Date|Bool|URL>",
                  "isRequired": true,
                  "defaultValue": null,
                  "parameterDescription": "<description>"
                }
              ],
              "exampleUsage": "<example invocation string>",
              "reliabilityScore": 0.7,
              "avgExecutionTimeMS": 1500
            }
          ],
          "applescriptActions": [
            {
              "functionName": "<snake_case_name>",
              "scriptTemplate": "<full AppleScript with {{param}} placeholders>",
              "actionDescription": "<what it does>",
              "parameters": ["param1", "param2"],
              "reliabilityScore": 0.9,
              "avgExecutionTimeMS": 2000
            }
          ],
          "shellCommands": [
            {
              "name": "<snake_case_name>",
              "command": "<binary name, e.g. open>",
              "argsTemplate": ["-a", "<AppName>"],
              "safetyCheck": null,
              "commandDescription": "<what it does>"
            }
          ],
          "commonPatterns": [
            {
              "userIntent": "<natural language, e.g. open safari>",
              "exampleActions": ["<function_name_1>", "<function_name_2>"]
            }
          ],
          "knownIssues": ["<issue 1>", "<issue 2>"],
          "timingHeuristics": {
            "launchDelay": 2000,
            "actionDelay": 1000
          }
        }

        RULES:
        1. Generate 3-8 applescriptActions based on the app's dictionary (most useful actions).
        2. Always include a shell command to launch the app via `open -a`.
        3. Always include an applescriptAction to activate/open the app.
        4. Only include appIntents if the app has known App Intents metadata.
        5. Generate 3-6 commonPatterns representing typical voice commands.
        6. Each commonPattern's exampleActions must reference functionNames/names defined above.
        7. scriptTemplate must be valid, complete AppleScript (tell application ... end tell).
        8. Use {{paramName}} for template placeholders in scriptTemplate.
        9. reliabilityScore: 0.95 for simple open/activate, 0.85-0.9 for standard actions, 0.7-0.8 for complex.
        10. Timing: launchDelay 1500-3000ms, actionDelay 500-2000ms depending on complexity.
        11. Return ONLY the JSON object, no markdown fences, no explanation.
        """

        return prompt
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, appName: String) throws -> [String: Any] {
        // Strip markdown fences if present
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogGeneratorError.parsingFailed(
                "Could not parse JSON for \(appName)"
            )
        }

        return json
    }

    // MARK: - Validation

    /// Mirrors the runtime `ActionCatalog` Codable schema
    /// (Console/Console/Command/Models/ActionCatalog.swift). A single entry
    /// that fails the runtime decode nils the whole catalog at app launch, so
    /// generation must reject anything the decoder would reject.
    func validateEntry(_ entry: [String: Any], appName: String) throws {
        let requiredKeys = [
            "name", "bundleID", "minMacOSVersion",
            "appIntents", "applescriptActions", "shellCommands",
            "commonPatterns", "knownIssues", "timingHeuristics"
        ]

        for key in requiredKeys {
            guard entry[key] != nil else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): missing required key '\(key)'"
                )
            }
        }

        guard entry["name"] is String, entry["bundleID"] is String,
              entry["minMacOSVersion"] is String else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): name, bundleID, and minMacOSVersion must be strings"
            )
        }

        guard let knownIssues = entry["knownIssues"] as? [String] else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): knownIssues must be an array of strings"
            )
        }
        _ = knownIssues

        guard let actions = entry["applescriptActions"] as? [[String: Any]] else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): applescriptActions must be an array of objects"
            )
        }

        for action in actions {
            guard let functionName = action["functionName"] as? String, !functionName.isEmpty,
                  action["scriptTemplate"] is String else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): each applescriptAction must have functionName and scriptTemplate"
                )
            }
            guard action["actionDescription"] is String,
                  action["parameters"] is [String],
                  let reliability = action["reliabilityScore"] as? Double,
                  let avgTime = action["avgExecutionTimeMS"] as? Int else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): applescriptAction '\(functionName)' is missing required fields " +
                    "(actionDescription: String, parameters: [String], " +
                    "reliabilityScore: Double, avgExecutionTimeMS: Int)"
                )
            }
            _ = reliability
            _ = avgTime
        }

        guard let shellCommands = entry["shellCommands"] as? [[String: Any]] else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): shellCommands must be an array of objects"
            )
        }

        for command in shellCommands {
            guard let name = command["name"] as? String, !name.isEmpty,
                  command["command"] is String,
                  command["argsTemplate"] is [String],
                  command["commandDescription"] is String else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): shellCommand must have name, command, argsTemplate (array), " +
                    "and commandDescription"
                )
            }
            if let safety = command["safetyCheck"], !(safety is String || safety is NSNull) {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): shellCommand '\(name)' safetyCheck must be a string or null"
                )
            }
        }

        guard let intents = entry["appIntents"] as? [[String: Any]] else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): appIntents must be an array of objects"
            )
        }

        for intent in intents {
            guard let intentName = intent["intentName"] as? String, !intentName.isEmpty else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): each appIntent must have intentName"
                )
            }
            guard intent["intentDescription"] is String,
                  intent["exampleUsage"] is String,
                  intent["reliabilityScore"] as? Double != nil,
                  intent["avgExecutionTimeMS"] as? Int != nil else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): appIntent '\(intentName)' is missing required fields " +
                    "(intentDescription, exampleUsage, reliabilityScore, avgExecutionTimeMS)"
                )
            }
            guard let parameters = intent["parameters"] as? [[String: Any]] else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): appIntent '\(intentName)' parameters must be an array of objects"
                )
            }
            for parameter in parameters {
                guard parameter["name"] is String,
                      parameter["type"] is String,
                      parameter["isRequired"] is Bool else {
                    throw CatalogGeneratorError.validationFailed(
                        "\(appName): appIntent '\(intentName)' parameters need name (String), " +
                        "type (String), isRequired (Bool)"
                    )
                }
                for optionalKey in ["defaultValue", "parameterDescription"] {
                    if let value = parameter[optionalKey], !(value is String || value is NSNull) {
                        throw CatalogGeneratorError.validationFailed(
                            "\(appName): appIntent '\(intentName)' parameter \(optionalKey) " +
                            "must be a string or null"
                        )
                    }
                }
            }
        }

        guard let heuristics = entry["timingHeuristics"] as? [String: Any],
              heuristics["launchDelay"] as? Int != nil,
              heuristics["actionDelay"] as? Int != nil else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): timingHeuristics must provide launchDelay (Int) and actionDelay (Int)"
            )
        }

        guard let patterns = entry["commonPatterns"] as? [[String: Any]] else {
            throw CatalogGeneratorError.validationFailed(
                "\(appName): commonPatterns must be an array of objects"
            )
        }

        // Collect all defined action names
        var definedNames = Set<String>()
        if let asActions = entry["applescriptActions"] as? [[String: Any]] {
            for a in asActions {
                if let name = a["functionName"] as? String { definedNames.insert(name) }
            }
        }
        if let shellCmds = entry["shellCommands"] as? [[String: Any]] {
            for c in shellCmds {
                if let name = c["name"] as? String { definedNames.insert(name) }
            }
        }
        if let intents = entry["appIntents"] as? [[String: Any]] {
            for i in intents {
                if let name = i["intentName"] as? String { definedNames.insert(name) }
            }
        }

        for pattern in patterns {
            guard pattern["userIntent"] is String,
                  let actionRefs = pattern["exampleActions"] as? [String] else {
                throw CatalogGeneratorError.validationFailed(
                    "\(appName): each commonPattern must have userIntent (string) and exampleActions (string array)"
                )
            }

            for ref in actionRefs {
                if !definedNames.contains(ref) && verbose {
                    print("  ⚠ \(appName): pattern references undefined action '\(ref)'")
                }
            }
        }
    }

    // MARK: - LLM API Communication

    private func sendRequest(systemPrompt: String, userMessage: String) async throws -> String {
        await rateLimit()

        switch config.provider {
        case .openAI:
            return try await sendOpenAI(system: systemPrompt, user: userMessage)
        case .claude:
            return try await sendClaude(system: systemPrompt, user: userMessage)
        case .gemini:
            return try await sendGemini(system: systemPrompt, user: userMessage)
        }
    }

    private func rateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minRequestInterval {
                let wait = minRequestInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    // MARK: - OpenAI

    private func sendOpenAI(system: String, user: String) async throws -> String {
        guard let url = URL(string: config.endpointURL) else {
            throw CatalogGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.2,
            "response_format": ["type": "json_object"]
        ]

        let headers = [
            "Authorization": "Bearer \(config.apiKey)",
            "Content-Type": "application/json"
        ]

        let data = try await performRequest(url: url, headers: headers, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CatalogGeneratorError.invalidResponse
        }
        return content
    }

    // MARK: - Claude

    private func sendClaude(system: String, user: String) async throws -> String {
        guard let url = URL(string: config.endpointURL) else {
            throw CatalogGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]

        let headers = [
            "x-api-key": config.apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"
        ]

        let data = try await performRequest(url: url, headers: headers, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw CatalogGeneratorError.invalidResponse
        }
        return text
    }

    // MARK: - Gemini

    private func sendGemini(system: String, user: String) async throws -> String {
        let urlString = "\(config.endpointURL)/\(config.model):generateContent?key=\(config.apiKey)"
        guard let url = URL(string: urlString) else {
            throw CatalogGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "\(system)\n\nUser request: \(user)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json"
            ]
        ]

        let headers = ["Content-Type": "application/json"]

        let data = try await performRequest(url: url, headers: headers, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw CatalogGeneratorError.invalidResponse
        }
        return text
    }

    // MARK: - Shared HTTP

    private func performRequest(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval = 60
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CatalogGeneratorError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CatalogGeneratorError.apiError("Invalid response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CatalogGeneratorError.apiError("[\(http.statusCode)] \(message)")
        }

        return data
    }
}
