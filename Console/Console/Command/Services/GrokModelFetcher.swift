import Foundation

// Last updated: 2026-02-10. Check https://docs.x.ai/docs for new models.
struct GrokModelFetcher: ModelFetcher {
    let apiKey: String
    let baseURL: String

    // Fallback list when /v1/models is unavailable
    private static let hardcodedModels: [AvailableModel] = [
        AvailableModel(id: "grok-2-latest", displayName: "Grok 2"),
        AvailableModel(id: "grok-2-1212", displayName: "Grok 2 (Dec 2024)"),
        AvailableModel(id: "grok-beta", displayName: "Grok Beta"),
    ]

    init(apiKey: String, config: AIProviderConfig) {
        self.apiKey = apiKey
        self.baseURL = config.endpointURL
            .replacingOccurrences(of: "/chat/completions", with: "")
    }

    func fetchAvailableModels() async throws -> [AvailableModel] {
        do {
            return try await fetchFromAPI()
        } catch let error as ModelFetchError where shouldFallback(error) {
            return Self.hardcodedModels
        }
    }

    private func fetchFromAPI() async throws -> [AvailableModel] {
        let url = URL(string: "\(baseURL)/models")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performProviderGETRequest(request)
        let httpResponse = response as? HTTPURLResponse

        switch httpResponse?.statusCode {
        case 200: break
        case 401, 403: throw ModelFetchError.unauthorized
        case 404: throw ModelFetchError.notSupported
        case 429: throw ModelFetchError.rateLimited
        default: throw ModelFetchError.invalidResponse
        }

        // xAI uses OpenAI-compatible format
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw ModelFetchError.invalidResponse
        }

        let grokModels = models.compactMap { model -> AvailableModel? in
            guard let id = model["id"] as? String else { return nil }
            return AvailableModel(id: id, displayName: displayName(for: id))
        }

        return grokModels.isEmpty ? Self.hardcodedModels : grokModels.sorted { $0.id > $1.id }
    }

    // Falls back to hardcoded list for non-auth errors
    private func shouldFallback(_ error: ModelFetchError) -> Bool {
        switch error {
        case .notSupported, .invalidResponse, .networkError, .serverUnreachable: return true
        case .unauthorized, .rateLimited: return false
        }
    }

    private func displayName(for id: String) -> String {
        let names: [String: String] = [
            "grok-2-latest": "Grok 2",
            "grok-2-1212": "Grok 2 (Dec 2024)",
            "grok-beta": "Grok Beta",
        ]
        return names[id] ?? id
    }
}
