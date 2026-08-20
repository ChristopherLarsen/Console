import Foundation

/// Fetches downloaded LLMs from LM Studio's native `GET /api/v1/models` endpoint.
struct LMStudioModelFetcher: ModelFetcher {
    let endpointURL: String

    init(config: AIProviderConfig) {
        self.endpointURL = config.endpointURL
    }

    func fetchAvailableModels() async throws -> [AvailableModel] {
        guard let url = LMStudioAPI.modelsURL(from: endpointURL) else {
            throw ModelFetchError.invalidResponse
        }

        let request = URLRequest(url: url, timeoutInterval: 8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performProviderGETRequest(request)
        } catch let error as ModelFetchError {
            if case .networkError(let underlying) = error, LMStudioAPI.isUnreachable(underlying) {
                throw ModelFetchError.serverUnreachable
            }
            throw error
        }

        let httpResponse = response as? HTTPURLResponse
        switch httpResponse?.statusCode {
        case 200: break
        case 401, 403: throw ModelFetchError.unauthorized
        case 429: throw ModelFetchError.rateLimited
        default: throw ModelFetchError.invalidResponse
        }

        return try LMStudioAPI.parseModels(data)
    }
}
