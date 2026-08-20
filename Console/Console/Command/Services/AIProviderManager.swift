import Foundation
import Observation

enum LastProviderRequest: Equatable {
    case none
    case succeeded
    case failed
}

@Observable
@MainActor
final class AIProviderManager {
    private let keychain = KeychainManager()

    /// Outcome of the last HTTP request to the selected AI provider. No polling — updated only when a request completes.
    private(set) var lastRequest: LastProviderRequest = .none

    var selectedProvider: AIProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: "selectedAIProvider") ?? AIProvider.none.rawValue
            let result = AIProvider(rawValue: raw) ?? .none
            return result
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectedAIProvider")
            UserDefaults.standard.synchronize()
            lastRequest = .none
        }
    }

    func recordLastRequest(success: Bool) {
        lastRequest = success ? .succeeded : .failed
    }

    /// Pings a local provider so the sidebar connection dot can show on launch.
    func pingSelectedLocalProviderIfNeeded() async {
        guard selectedProvider == .lmStudio else { return }
        _ = await testConnection(for: .lmStudio)
    }

    func config(for provider: AIProvider) -> AIProviderConfig {
        let stored = loadStoredConfig(for: provider)
        var cfg = stored ?? AIProviderConfig.defaultConfigs[provider] ?? AIProviderConfig(
            provider: provider,
            endpointURL: "",
            apiKeyKeychainRef: "ai-provider-\(provider.rawValue)",
            modelName: ""
        )
        if provider == .lmStudio {
            cfg.endpointURL = LMStudioAPI.origin(from: cfg.endpointURL)
        }
        return cfg
    }

    func saveConfig(_ config: AIProviderConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: "aiConfig-\(config.provider.rawValue)")
        UserDefaults.standard.synchronize()
    }

    func saveAPIKey(_ key: String, for provider: AIProvider) async throws {
        let ref = config(for: provider).apiKeyKeychainRef
        try await keychain.save(token: key, for: ref)
    }

    /// Saves an API key to Keychain, returning a Result instead of throwing.
    func saveAPIKeyToKeychain(_ key: String, for provider: AIProvider) async -> Result<Void, KeychainManager.KeychainError> {
        let ref = config(for: provider).apiKeyKeychainRef
        do {
            try await keychain.save(token: key, for: ref)
            return .success(())
        } catch let error as KeychainManager.KeychainError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedError(-1))
        }
    }

    func loadAPIKey(for provider: AIProvider) async -> String? {
        let ref = config(for: provider).apiKeyKeychainRef
        return try? await keychain.retrieve(for: ref)
    }

    /// Loads an API key from Keychain, returning a Result instead of nil.
    func loadAPIKeyFromKeychain(for provider: AIProvider) async -> Result<String?, KeychainManager.KeychainError> {
        let ref = config(for: provider).apiKeyKeychainRef
        do {
            let key = try await keychain.retrieve(for: ref)
            return .success(key)
        } catch KeychainManager.KeychainError.itemNotFound {
            return .success(nil)
        } catch let error as KeychainManager.KeychainError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedError(-1))
        }
    }

    func deleteAPIKey(for provider: AIProvider) async throws {
        let ref = config(for: provider).apiKeyKeychainRef
        try await keychain.delete(for: ref)
    }

    enum ConnectionTestResult: Equatable {
        case idle
        case testing
        case success
        case invalidKey
        case rateLimited
        case networkError(String)
        case error(String)

        var label: String {
            switch self {
            case .idle: return ""
            case .testing: return "Testing..."
            case .success: return "Connected"
            case .invalidKey: return "Invalid API key"
            case .rateLimited: return "Rate limited"
            case .networkError(let msg): return "Network error: \(msg)"
            case .error(let msg): return msg
            }
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    func testConnection(for provider: AIProvider) async -> ConnectionTestResult {
        guard provider != .none else { return .error("No provider selected") }

        let cfg = config(for: provider)
        if provider == .lmStudio {
            return await pingLMStudio(cfg)
        }

        let storedKey = await loadAPIKey(for: provider)
        if provider.requiresAPIKey {
            guard let apiKey = storedKey, !apiKey.isEmpty else {
                return .invalidKey
            }
        }
        let apiKey = effectiveAPIKey(stored: storedKey, for: provider)

        guard let url = URL(string: cfg.endpointURL) else {
            return .error("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider {
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": cfg.modelName,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": cfg.modelName,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        case .gemini:
            var components = URLComponents(string: cfg.endpointURL)
            components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let geminiURL = components?.url else {
                return .error("Invalid Gemini URL")
            }
            request.url = geminiURL
            let body: [String: Any] = [
                "contents": [["parts": [["text": "ping"]]]]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        case .grok:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": cfg.modelName,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        case .lmStudio, .none:
            return .error("No provider")
        }

        let actualURL = request.url?.absoluteString ?? "<nil>"
        let requestBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty>"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                printConnectionFailure(
                    reason: "unexpected response type",
                    provider: provider, endpoint: actualURL, model: cfg.modelName,
                    requestBody: requestBody, responseBody: nil, statusCode: nil
                )
                recordLastRequest(success: false)
                return .error("Unexpected response")
            }
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            switch http.statusCode {
            case 200..<300:
                recordLastRequest(success: true)
                return .success
            case 401, 403:
                printConnectionFailure(
                    reason: "HTTP \(http.statusCode) (invalid key)",
                    provider: provider, endpoint: actualURL, model: cfg.modelName,
                    requestBody: requestBody, responseBody: body, statusCode: http.statusCode
                )
                recordLastRequest(success: false)
                return .invalidKey
            case 429:
                printConnectionFailure(
                    reason: "HTTP 429 (rate limited)",
                    provider: provider, endpoint: actualURL, model: cfg.modelName,
                    requestBody: requestBody, responseBody: body, statusCode: http.statusCode
                )
                recordLastRequest(success: false)
                return .rateLimited
            default:
                printConnectionFailure(
                    reason: "HTTP \(http.statusCode)",
                    provider: provider, endpoint: actualURL, model: cfg.modelName,
                    requestBody: requestBody, responseBody: body, statusCode: http.statusCode,
                    headers: http.allHeaderFields
                )
                let msg = String(body.prefix(120))
                recordLastRequest(success: false)
                return .error("[\(http.statusCode)] \(msg)")
            }
        } catch let error as URLError {
            printConnectionFailure(
                reason: "network error",
                provider: provider, endpoint: actualURL, model: cfg.modelName,
                requestBody: requestBody, responseBody: nil, statusCode: nil,
                errorDetail: "URLError code: \(error.code.rawValue) (\(error.localizedDescription))"
            )
            recordLastRequest(success: false)
            return .networkError(error.localizedDescription)
        } catch {
            printConnectionFailure(
                reason: "unexpected error",
                provider: provider, endpoint: actualURL, model: cfg.modelName,
                requestBody: requestBody, responseBody: nil, statusCode: nil,
                errorDetail: "\(error)"
            )
            recordLastRequest(success: false)
            return .error(error.localizedDescription)
        }
    }

    func generator() async -> (any LLMCommandGenerator)? {
        let provider = selectedProvider
        guard provider != .none else { return nil }

        let storedKey = await loadAPIKey(for: provider)
        if provider.requiresAPIKey {
            guard let apiKey = storedKey, !apiKey.isEmpty else { return nil }
        }
        let apiKey = effectiveAPIKey(stored: storedKey, for: provider)
        let cfg = config(for: provider)

        switch provider {
        case .openAI:
            return OpenAICommandGenerator(apiKey: apiKey, config: cfg)
        case .claude:
            return ClaudeCommandGenerator(apiKey: apiKey, config: cfg)
        case .gemini:
            return GeminiCommandGenerator(apiKey: apiKey, config: cfg)
        case .grok:
            return GrokCommandGenerator(apiKey: apiKey, config: cfg)
        case .lmStudio:
            return LMStudioCommandGenerator(apiKey: apiKey, config: cfg)
        case .none:
            return nil
        }
    }

    /// Resolves the Bearer/API key to use for requests. Local providers omit a key.
    func effectiveAPIKey(stored: String?, for provider: AIProvider) -> String {
        if let stored, !stored.isEmpty { return stored }
        return ""
    }

    /// Pings LM Studio with `GET /api/v1/models` — no chat, no API key, no loaded model required.
    private func pingLMStudio(_ cfg: AIProviderConfig) async -> ConnectionTestResult {
        guard let url = LMStudioAPI.modelsURL(from: cfg.endpointURL) else {
            return .error("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        let endpoint = url.absoluteString
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                printConnectionFailure(
                    reason: "unexpected response type",
                    provider: .lmStudio, endpoint: endpoint, model: cfg.modelName,
                    requestBody: "<GET>", responseBody: nil, statusCode: nil
                )
                recordLastRequest(success: false)
                return .error("Unexpected response")
            }
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            switch http.statusCode {
            case 200..<300:
                recordLastRequest(success: true)
                return .success
            case 401, 403:
                printConnectionFailure(
                    reason: "HTTP \(http.statusCode) (invalid key)",
                    provider: .lmStudio, endpoint: endpoint, model: cfg.modelName,
                    requestBody: "<GET>", responseBody: body, statusCode: http.statusCode
                )
                recordLastRequest(success: false)
                return .invalidKey
            default:
                printConnectionFailure(
                    reason: "HTTP \(http.statusCode)",
                    provider: .lmStudio, endpoint: endpoint, model: cfg.modelName,
                    requestBody: "<GET>", responseBody: body, statusCode: http.statusCode,
                    headers: http.allHeaderFields
                )
                recordLastRequest(success: false)
                return .error("[\(http.statusCode)] \(String(body.prefix(120)))")
            }
        } catch let error as URLError {
            printConnectionFailure(
                reason: "network error",
                provider: .lmStudio, endpoint: endpoint, model: cfg.modelName,
                requestBody: "<GET>", responseBody: nil, statusCode: nil,
                errorDetail: "URLError code: \(error.code.rawValue) (\(error.localizedDescription))"
            )
            recordLastRequest(success: false)
            if LMStudioAPI.isUnreachable(error) {
                let origin = LMStudioAPI.origin(from: cfg.endpointURL)
                return .networkError("Could not reach LM Studio at \(origin). Start the local server (Developer tab or lms server start) and try again.")
            }
            return .networkError(error.localizedDescription)
        } catch {
            printConnectionFailure(
                reason: "unexpected error",
                provider: .lmStudio, endpoint: endpoint, model: cfg.modelName,
                requestBody: "<GET>", responseBody: nil, statusCode: nil,
                errorDetail: "\(error)"
            )
            recordLastRequest(success: false)
            return .error(error.localizedDescription)
        }
    }

    private func loadStoredConfig(for provider: AIProvider) -> AIProviderConfig? {
        guard let data = UserDefaults.standard.data(forKey: "aiConfig-\(provider.rawValue)") else {
            return nil
        }
        let decoded = try? JSONDecoder().decode(AIProviderConfig.self, from: data)
        return decoded
    }

    // Prints detailed connection failure info to the debug console
    private func printConnectionFailure(
        reason: String,
        provider: AIProvider,
        endpoint: String,
        model: String,
        requestBody: String,
        responseBody: String?,
        statusCode: Int?,
        headers: [AnyHashable: Any]? = nil,
        errorDetail: String? = nil
    ) {
        printDebug("[Console] ── Connection Test Failed ──")
        printDebug("[Console]   Reason:   \(reason)")
        printDebug("[Console]   Provider: \(provider.rawValue)")
        printDebug("[Console]   Endpoint: \(endpoint)")
        printDebug("[Console]   Model:    \(model)")
        if let code = statusCode {
            printDebug("[Console]   Status:   \(code)")
        }
        printDebug("[Console]   Request body: \(requestBody)")
        if let body = responseBody {
            printDebug("[Console]   Response body: \(body)")
        }
        if let detail = errorDetail {
            printDebug("[Console]   Error detail: \(detail)")
        }
        if let hdrs = headers {
            let relevant = hdrs.compactMap { key, val -> String? in
                let k = "\(key)".lowercased()
                guard k.contains("content") || k.contains("retry") || k.contains("error") || k.contains("x-") else { return nil }
                return "    \(key): \(val)"
            }
            if !relevant.isEmpty {
                printDebug("[Console]   Response headers:")
                relevant.forEach { printDebug("[Console]   \($0)") }
            }
        }
        printDebug("[Console] ────────────────────────────")
    }
}
