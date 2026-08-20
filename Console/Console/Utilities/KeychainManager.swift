import Foundation
import Security

actor KeychainManager {
    enum KeychainError: Error {
        case duplicateItem
        case itemNotFound
        case permissionDenied
        case userCanceled
        case interactionNotAllowed
        case unexpectedError(OSStatus)
        case encodingFailed
        case decodingFailed

        var userMessage: String {
            switch self {
            case .duplicateItem:
                return "This item already exists in the Keychain."
            case .itemNotFound:
                return "The requested item was not found in the Keychain."
            case .permissionDenied:
                return "Keychain access was denied. Please allow Keychain access in System Settings > Privacy & Security."
            case .userCanceled:
                return "Keychain access was canceled. Your API key was not saved."
            case .interactionNotAllowed:
                return "Keychain access requires the device to be unlocked."
            case .unexpectedError(let status):
                return "Keychain operation failed (error \(status)). Please try again."
            case .encodingFailed:
                return "Failed to encode data for Keychain storage."
            case .decodingFailed:
                return "Failed to decode data from Keychain."
            }
        }

        /// Maps a Security framework OSStatus to a typed KeychainError.
        static func fromStatus(_ status: OSStatus) -> KeychainError {
            switch status {
            case errSecAuthFailed:
                return .permissionDenied
            case errSecUserCanceled:
                return .userCanceled
            case errSecInteractionNotAllowed:
                return .interactionNotAllowed
            case errSecDuplicateItem:
                return .duplicateItem
            case errSecItemNotFound:
                return .itemNotFound
            default:
                return .unexpectedError(status)
            }
        }
    }

    /// Service name for Keychain items; required for reliable persistence and uniqueness.
    /// Keep stable across builds to avoid orphaned items.
    private static let serviceName = "com.console.console"
    /// Legacy service name fallback for older builds (bundle identifier).
    private static let legacyServiceName = Bundle.main.bundleIdentifier ?? "Console"
    
    /// Prefix for cloud server credential keys
    private static let cloudServerPrefix = "cloud-server-"
    
    /// Key for storing the list of saved cloud server IDs
    private static let cloudServerListKey = "cloud-server-list"
    
    // MARK: - Access Check

    /// Probes the Keychain with a no-op query to determine if the app can
    /// access its items without triggering a system permission dialog.
    static func checkKeychainAccessStatus() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "keychain-access-probe",
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // Both indicate the app has Keychain access
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Cloud Server Credentials
    
    /// Credentials stored for a cloud server
    struct CloudServerCredential: Codable, Equatable {
        let id: String
        let displayName: String
        let address: String
        let port: Int
        var apiKey: String?
        var lastConnected: Date?
        var region: String?
    }
    
    /// Save cloud server credentials to Keychain
    func saveCloudServer(_ credential: CloudServerCredential) throws {
        guard let data = try? JSONEncoder().encode(credential) else {
            throw KeychainError.encodingFailed
        }
        
        let key = Self.cloudServerPrefix + credential.id
        try saveData(data, for: key)
        
        // Update the server list
        var serverIds = (try? loadCloudServerIds()) ?? []
        if !serverIds.contains(credential.id) {
            serverIds.append(credential.id)
            try saveCloudServerIds(serverIds)
        }
    }
    
    /// Load a specific cloud server credential
    func loadCloudServer(id: String) throws -> CloudServerCredential {
        let key = Self.cloudServerPrefix + id
        let data = try retrieveData(for: key)
        
        guard let credential = try? JSONDecoder().decode(CloudServerCredential.self, from: data) else {
            throw KeychainError.decodingFailed
        }
        
        return credential
    }
    
    /// Load all saved cloud server credentials
    func loadAllCloudServers() throws -> [CloudServerCredential] {
        let serverIds = (try? loadCloudServerIds()) ?? []
        
        return serverIds.compactMap { id in
            try? loadCloudServer(id: id)
        }
    }
    
    /// Delete a cloud server credential
    func deleteCloudServer(id: String) throws {
        let key = Self.cloudServerPrefix + id
        try delete(for: key)
        
        // Update the server list
        var serverIds = (try? loadCloudServerIds()) ?? []
        serverIds.removeAll { $0 == id }
        try saveCloudServerIds(serverIds)
    }
    
    /// Update last connected time for a cloud server
    func updateCloudServerLastConnected(id: String, date: Date) throws {
        var credential = try loadCloudServer(id: id)
        credential.lastConnected = date
        try saveCloudServer(credential)
    }
    
    // MARK: - Private Cloud Server Helpers
    
    private func loadCloudServerIds() throws -> [String] {
        let data = try retrieveData(for: Self.cloudServerListKey)
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
            throw KeychainError.decodingFailed
        }
        return ids
    }
    
    private func saveCloudServerIds(_ ids: [String]) throws {
        guard let data = try? JSONEncoder().encode(ids) else {
            throw KeychainError.encodingFailed
        }
        try saveData(data, for: Self.cloudServerListKey)
    }
    
    // MARK: - Generic Data Storage
    
    private func saveData(_ data: Data, for identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecDuplicateItem {
            try updateData(data, for: identifier)
        } else if status != errSecSuccess {
            throw KeychainError.fromStatus(status)
        }
    }
    
    private func retrieveData(for identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.fromStatus(status)
        }
        
        return data
    }
    
    private func updateData(_ data: Data, for identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier
        ]
        
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess {
            throw KeychainError.fromStatus(status)
        }
    }
    
    // MARK: - Token Storage (Legacy API)

    func save(token: String, for identifier: String) throws {
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            try update(token: token, for: identifier)
        } else if status != errSecSuccess {
            throw KeychainError.fromStatus(status)
        }
    }

    func retrieve(for identifier: String) throws -> String {
        do {
            return try retrieveWithService(identifier)
        } catch KeychainError.itemNotFound {
            // Migration: token may have been saved before kSecAttrService was added
            if let legacy = try? retrieveLegacy(identifier) {
                try? save(token: legacy, for: identifier)
                return legacy
            }
            if let legacy = try? retrieveLegacyService(identifier) {
                try? save(token: legacy, for: identifier)
                return legacy
            }
            throw KeychainError.itemNotFound
        } catch {
            // Permission and other errors propagate immediately
            throw error
        }
    }

    private func retrieveWithService(_ identifier: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw KeychainError.fromStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }

        return token
    }

    /// Legacy lookup without kSecAttrService (for tokens saved before we added service name).
    private func retrieveLegacy(_ identifier: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }

        return token
    }

    /// Legacy lookup with older service name (bundle identifier), before we stabilized it.
    private func retrieveLegacyService(_ identifier: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyServiceName,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }

        return token
    }

    func delete(for identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.fromStatus(status)
        }
    }

    private func update(token: String, for identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: identifier
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8)
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess {
            throw KeychainError.fromStatus(status)
        }
    }
}
