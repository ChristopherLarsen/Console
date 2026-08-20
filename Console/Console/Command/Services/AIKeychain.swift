import Foundation

extension KeychainManager {
    private static let aiProviderKeyPrefix = "ai-provider-"

    func saveAIProviderKey(_ apiKey: String, for provider: AIProvider) throws {
        let identifier = Self.aiProviderKeyPrefix + provider.rawValue
        try save(token: apiKey, for: identifier)
    }

    func loadAIProviderKey(for provider: AIProvider) throws -> String {
        let identifier = Self.aiProviderKeyPrefix + provider.rawValue
        return try retrieve(for: identifier)
    }

    func deleteAIProviderKey(for provider: AIProvider) throws {
        let identifier = Self.aiProviderKeyPrefix + provider.rawValue
        try delete(for: identifier)
    }
}
