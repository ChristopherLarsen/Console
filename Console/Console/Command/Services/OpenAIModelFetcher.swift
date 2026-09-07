import Foundation

struct OpenAIModelFetcher: ModelFetcher {
    let apiKey: String
    let provider: AIProvider
    let baseURL: String

    private static let chatPrefixes = ["gpt-", "o1", "o3", "o4"]

    private static let displayNames: [String: String] = [
        "gpt-4o": "GPT-4o",
        "gpt-4o-mini": "GPT-4o Mini",
        "gpt-4-turbo": "GPT-4 Turbo",
        "gpt-4": "GPT-4",
        "o1": "o1",
        "o1-mini": "o1 Mini",
        "o1-preview": "o1 Preview",
        "o3": "o3",
        "o3-mini": "o3 Mini",
    ]

    // Aliases that resolve to a canonical model — show the alias, not the snapshot
    private static let aliases: Set<String> = [
        "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4", "o1", "o1-mini", "o3", "o3-mini"
    ]

    init(apiKey: String, config: AIProviderConfig) {
        self.apiKey = apiKey
        self.provider = config.provider
        // Derive base URL from chat completions endpoint
        self.baseURL = config.endpointURL
            .replacingOccurrences(of: "/chat/completions", with: "")
    }

    func fetchAvailableModels() async throws -> [AvailableModel] {
        let url = URL(string: "\(baseURL)/models")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performProviderGETRequest(request, provider: provider)
        let httpResponse = response as? HTTPURLResponse

        switch httpResponse?.statusCode {
        case 200: break
        case 401, 403: throw ModelFetchError.unauthorized
        case 429: throw ModelFetchError.rateLimited
        default: throw ModelFetchError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw ModelFetchError.invalidResponse
        }

        // Collect all IDs to detect alias/snapshot pairs
        let allIDs = Set(models.compactMap { $0["id"] as? String })

        let chatModels = models.compactMap { model -> AvailableModel? in
            guard let id = model["id"] as? String else { return nil }
            guard Self.chatPrefixes.contains(where: { id.hasPrefix($0) }) else { return nil }
            if isDeprecated(id) { return nil }
            if isDatedSnapshot(id, allIDs: allIDs) { return nil }

            let displayName = Self.displayNames[id] ?? id
            return AvailableModel(id: id, displayName: displayName)
        }

        return chatModels.sorted { $0.id > $1.id }
    }

    private func isDeprecated(_ id: String) -> Bool {
        let deprecated: Set<String> = [
            "gpt-3.5-turbo-0301", "gpt-3.5-turbo-0613", "gpt-3.5-turbo-1106",
            "gpt-4-0314", "gpt-4-0613", "gpt-4-1106-preview",
            "gpt-4-vision-preview", "gpt-4-32k-0314", "gpt-4-32k-0613",
        ]
        if deprecated.contains(id) { return true }
        if id.contains("instruct") { return true }
        return false
    }

    // Hides dated snapshots (e.g. "gpt-4o-2024-08-06") when the alias exists
    private func isDatedSnapshot(_ id: String, allIDs: Set<String>) -> Bool {
        let datePattern = #"-\d{4}-\d{2}-\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: datePattern),
              regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else {
            return false
        }
        let base = id.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        return Self.aliases.contains(base) && allIDs.contains(base)
    }
}
