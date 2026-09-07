import Foundation

final class ModelCacheManager: @unchecked Sendable {
    static let shared = ModelCacheManager()

    private let queue = DispatchQueue(label: "com.console.modelcache")

    /// Cache entries are scoped to the exact configuration that produced them:
    /// changing the endpoint or API key must never serve the prior list.
    private struct CacheKey: Hashable {
        let provider: AIProvider
        let endpointURL: String
        let apiKey: String
    }

    private var cache: [CacheKey: CachedModels] = [:]

    private struct CachedModels {
        let models: [AvailableModel]
        let timestamp: Date
        let ttl: TimeInterval = 3600

        var isValid: Bool {
            Date().timeIntervalSince(timestamp) < ttl
        }
    }

    private init() {}

    func getCachedModels(for provider: AIProvider, endpointURL: String, apiKey: String) -> [AvailableModel]? {
        queue.sync {
            guard let entry = cache[CacheKey(provider: provider, endpointURL: endpointURL, apiKey: apiKey)],
                  entry.isValid else { return nil }
            return entry.models
        }
    }

    func cacheModels(_ models: [AvailableModel], for provider: AIProvider, endpointURL: String, apiKey: String) {
        queue.sync {
            cache[CacheKey(provider: provider, endpointURL: endpointURL, apiKey: apiKey)] =
                CachedModels(models: models, timestamp: Date())
        }
    }

    func invalidateCache(for provider: AIProvider) {
        _ = queue.sync {
            cache = cache.filter { $0.key.provider != provider }
        }
    }

    func clearAllCaches() {
        queue.sync {
            cache.removeAll()
        }
    }
}
