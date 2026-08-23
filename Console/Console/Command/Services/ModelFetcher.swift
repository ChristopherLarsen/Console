import Foundation

nonisolated struct AvailableModel: Identifiable, Sendable {
    let id: String
    let displayName: String
    let description: String?

    init(id: String, displayName: String, description: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}

protocol ModelFetcher: Sendable {
    func fetchAvailableModels() async throws -> [AvailableModel]
}

enum ModelFetchError: LocalizedError {
    case networkError(Error)
    case invalidResponse
    case unauthorized
    case notSupported
    case rateLimited
    case serverUnreachable

    var errorDescription: String? {
        switch self {
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse: return "Unable to parse model list response"
        case .unauthorized: return "API key is invalid or expired"
        case .notSupported: return "Provider does not support model listing"
        case .rateLimited: return "Too many requests — try again later"
        case .serverUnreachable:
            return "Could not reach LM Studio. Start the local server (Developer tab or lms server start) and try again."
        }
    }
}
