import Foundation

final class ModelCacheManager: @unchecked Sendable {
    static let shared = ModelCacheManager()

    private let queue = DispatchQueue(label: "com.console.modelcache")
    private var cache: [AIProvider: CachedModels] = [:]

    private struct CachedModels {
        let models: [AvailableModel]
        let timestamp: Date
        let ttl: TimeInterval = 3600

        var isValid: Bool {
            Date().timeIntervalSince(timestamp) < ttl
        }
    }

    private init() {}

    func getCachedModels(for provider: AIProvider) -> [AvailableModel]? {
        queue.sync {
            guard let entry = cache[provider], entry.isValid else { return nil }
            return entry.models
        }
    }

    func cacheModels(_ models: [AvailableModel], for provider: AIProvider) {
        queue.sync {
            cache[provider] = CachedModels(models: models, timestamp: Date())
        }
    }

    func invalidateCache(for provider: AIProvider) {
        _ = queue.sync {
            cache.removeValue(forKey: provider)
        }
    }

    func clearAllCaches() {
        queue.sync {
            cache.removeAll()
        }
    }
}
