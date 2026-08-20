import Foundation

// MARK: - LLM Client Protocol

protocol LLMClient: Sendable {
    func sendMessage(systemPrompt: String, userMessage: String) async throws -> String
}

// MARK: - Rate Limiter

final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRequestTime: Date?
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval = 0.5) {
        self.minInterval = minInterval
    }

    func waitIfNeeded() async {
        let waitTime: TimeInterval? = lock.withLock {
            guard let last = lastRequestTime else {
                lastRequestTime = Date()
                return nil
            }
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                let wait = minInterval - elapsed
                lastRequestTime = Date().addingTimeInterval(wait)
                return wait
            }
            lastRequestTime = Date()
            return nil
        }

        if let wait = waitTime {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

// MARK: - Shared Networking

/// Records last provider HTTP outcome on the shared AIProviderManager (no-op if unset).
func recordProviderRequestOutcome(success: Bool) {
    Task { @MainActor in
        AppDependencies.shared.aiProviderManager?.recordLastRequest(success: success)
    }
}

/// Shared GET helper for model-list fetchers. Records 2xx vs failure before returning.
func performProviderGETRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        recordProviderRequestOutcome(success: false)
        throw ModelFetchError.networkError(error)
    }

    if let http = response as? HTTPURLResponse {
        recordProviderRequestOutcome(success: (200..<300).contains(http.statusCode))
    } else {
        recordProviderRequestOutcome(success: false)
    }

    return (data, response)
}

private func performHTTPRequest(
    url: URL,
    headers: [String: String],
    body: [String: Any],
    timeout: TimeInterval = 30
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
        recordProviderRequestOutcome(success: false)
        throw LLMGeneratorError.networkError(error)
    }

    guard let http = response as? HTTPURLResponse else {
        recordProviderRequestOutcome(success: false)
        throw LLMGeneratorError.apiError("Invalid response")
    }

    guard (200..<300).contains(http.statusCode) else {
        recordProviderRequestOutcome(success: false)
        let message = String(data: data, encoding: .utf8) ?? "Unknown error"

        if http.statusCode == 429 {
            throw LLMGeneratorError.apiError("[429] Rate limit exceeded. \(message)")
        }
        throw LLMGeneratorError.apiError("[\(http.statusCode)] \(message)")
    }

    recordProviderRequestOutcome(success: true)
    return data
}

// MARK: - OpenAI Client

struct OpenAIClient: LLMClient {
    let apiKey: String
    let config: AIProviderConfig
    private let rateLimiter = RateLimiter()

    func sendMessage(systemPrompt: String, userMessage: String) async throws -> String {
        await rateLimiter.waitIfNeeded()

        guard let url = URL(string: config.endpointURL) else {
            throw LLMGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.3,
            "response_format": ["type": "json_object"]
        ]

        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json"
        ]

        let data = try await performHTTPRequest(url: url, headers: headers, body: body)
        return try extractOpenAIText(data)
    }

    private func extractOpenAIText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMGeneratorError.invalidResponse
        }
        return content
    }
}

// MARK: - Claude Client

struct ClaudeClient: LLMClient {
    let apiKey: String
    let config: AIProviderConfig
    private let rateLimiter = RateLimiter()

    func sendMessage(systemPrompt: String, userMessage: String) async throws -> String {
        await rateLimiter.waitIfNeeded()

        guard let url = URL(string: config.endpointURL) else {
            throw LLMGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "model": config.modelName,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"
        ]

        let data = try await performHTTPRequest(url: url, headers: headers, body: body)
        return try extractClaudeText(data)
    }

    private func extractClaudeText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw LLMGeneratorError.invalidResponse
        }
        return text
    }
}

// MARK: - Gemini Client

struct GeminiClient: LLMClient {
    let apiKey: String
    let config: AIProviderConfig
    private let rateLimiter = RateLimiter()

    func sendMessage(systemPrompt: String, userMessage: String) async throws -> String {
        await rateLimiter.waitIfNeeded()

        let urlString = "\(config.endpointURL)/\(config.modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw LLMGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "\(systemPrompt)\n\nUser request: \(userMessage)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json"
            ]
        ]

        let headers = ["Content-Type": "application/json"]

        let data = try await performHTTPRequest(url: url, headers: headers, body: body)
        return try extractGeminiText(data)
    }

    private func extractGeminiText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LLMGeneratorError.invalidResponse
        }
        return text
    }
}

// MARK: - Grok Client

struct GrokClient: LLMClient {
    let apiKey: String
    let config: AIProviderConfig
    private let rateLimiter = RateLimiter()

    func sendMessage(systemPrompt: String, userMessage: String) async throws -> String {
        await rateLimiter.waitIfNeeded()

        guard let url = URL(string: config.endpointURL) else {
            throw LLMGeneratorError.apiError("Invalid endpoint URL")
        }

        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.3,
            "response_format": ["type": "json_object"]
        ]

        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json"
        ]

        let data = try await performHTTPRequest(url: url, headers: headers, body: body)
        return try extractGrokText(data)
    }

    private func extractGrokText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMGeneratorError.invalidResponse
        }
        return content
    }
}

// MARK: - LM Studio Client

/// Native LM Studio client (`POST /api/v1/chat`).
/// Uses `input` + `system_prompt` rather than OpenAI `messages`.
struct LMStudioClient: LLMClient {
    let apiKey: String
    let config: AIProviderConfig
    private let rateLimiter = RateLimiter()

    func sendMessage(systemPrompt: String, userMessage: String) async throws -> String {
        await rateLimiter.waitIfNeeded()

        guard let url = LMStudioAPI.chatURL(from: config.endpointURL) else {
            throw LLMGeneratorError.apiError("Invalid endpoint URL")
        }

        do {
            let data = try await postChat(
                url: url,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                includeReasoningOff: true
            )
            return try LMStudioAPI.extractChatText(data)
        } catch let LLMGeneratorError.apiError(message) where message.lowercased().contains("reasoning") {
            let data = try await postChat(
                url: url,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                includeReasoningOff: false
            )
            return try LMStudioAPI.extractChatText(data)
        }
    }

    private func postChat(
        url: URL,
        systemPrompt: String,
        userMessage: String,
        includeReasoningOff: Bool
    ) async throws -> Data {
        var body: [String: Any] = [
            "model": config.modelName,
            "input": userMessage,
            "system_prompt": systemPrompt,
            "temperature": 0.3,
            "store": false
        ]
        if includeReasoningOff {
            body["reasoning"] = "off"
        }

        var headers = ["Content-Type": "application/json"]
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        return try await performHTTPRequest(url: url, headers: headers, body: body, timeout: 120)
    }
}

// MARK: - Factory

enum LLMClientFactory {
    static func makeClient(provider: AIProvider, apiKey: String, config: AIProviderConfig) -> (any LLMClient)? {
        switch provider {
        case .openAI:
            return OpenAIClient(apiKey: apiKey, config: config)
        case .claude:
            return ClaudeClient(apiKey: apiKey, config: config)
        case .gemini:
            return GeminiClient(apiKey: apiKey, config: config)
        case .grok:
            return GrokClient(apiKey: apiKey, config: config)
        case .lmStudio:
            return LMStudioClient(apiKey: apiKey, config: config)
        case .none:
            return nil
        }
    }
}
