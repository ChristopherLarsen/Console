import Foundation

struct GeminiModelFetcher: ModelFetcher {
    let apiKey: String
    let provider: AIProvider
    let endpointURL: String

    private static let displayNames: [String: String] = [
        "gemini-2.0-flash": "Gemini 2.0 Flash",
        "gemini-2.0-flash-lite": "Gemini 2.0 Flash Lite",
        "gemini-1.5-pro": "Gemini 1.5 Pro",
        "gemini-1.5-flash": "Gemini 1.5 Flash",
        "gemini-1.5-flash-8b": "Gemini 1.5 Flash 8B",
    ]

    init(apiKey: String, config: AIProviderConfig) {
        self.apiKey = apiKey
        self.provider = config.provider
        self.endpointURL = config.endpointURL
    }

    /// The config's endpoint is the `…/v1beta/models` list base (the same base
    /// `GeminiClient` appends `/{model}:generateContent` to).
    static func modelsURL(endpointURL: String, apiKey: String) -> URL? {
        URL(string: "\(endpointURL)?key=\(apiKey)")
    }

    func fetchAvailableModels() async throws -> [AvailableModel] {
        guard let url = Self.modelsURL(endpointURL: endpointURL, apiKey: apiKey) else {
            throw ModelFetchError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"

        let (data, response) = try await performProviderGETRequest(request, provider: provider)
        let httpResponse = response as? HTTPURLResponse

        switch httpResponse?.statusCode {
        case 200: break
        case 401, 403: throw ModelFetchError.unauthorized
        case 429: throw ModelFetchError.rateLimited
        default: throw ModelFetchError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw ModelFetchError.invalidResponse
        }

        let geminiModels = models.compactMap { model -> AvailableModel? in
            guard let name = model["name"] as? String else { return nil }

            // Only include models that support content generation
            if let methods = model["supportedGenerationMethods"] as? [String],
               !methods.contains("generateContent") { return nil }

            let id = name.replacingOccurrences(of: "models/", with: "")
            guard id.contains("gemini") else { return nil }
            if isExperimentalOrThinking(id) { return nil }

            let displayName = Self.displayNames[id] ?? id
            return AvailableModel(id: id, displayName: displayName)
        }

        return geminiModels.sorted { $0.id > $1.id }
    }

    private func isExperimentalOrThinking(_ id: String) -> Bool {
        let excluded = ["exp", "experimental", "thinking"]
        return excluded.contains(where: { id.localizedCaseInsensitiveContains($0) })
    }
}
