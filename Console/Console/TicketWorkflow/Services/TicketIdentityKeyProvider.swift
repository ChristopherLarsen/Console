import Foundation
import Security

/// Package-B Keychain identity for opaque ticket association.
/// Uses a dedicated service/account — never AI provider key accounts.
actor TicketIdentityKeyProvider: TicketIdentityKeyManaging {
    /// Dedicated service; do not reuse `com.console.console` AI-key items.
    nonisolated static let serviceName = "com.console.ticket-workflow"
    nonisolated static let accountName = "installation-identity-secret"
    nonisolated static let secretByteCount = 32

    private let service: String
    private let account: String
    private let createIfMissing: Bool

    /// - Parameter createIfMissing: When `false`, `installationSecret()` throws
    ///   `.missingIdentityKey` instead of minting a new secret (recovery path).
    init(
        service: String = TicketIdentityKeyProvider.serviceName,
        account: String = TicketIdentityKeyProvider.accountName,
        createIfMissing: Bool = true
    ) {
        self.service = service
        self.account = account
        self.createIfMissing = createIfMissing
    }

    func installationSecret() async throws -> Data {
        do {
            return try readSecret()
        } catch TicketWorkflowPersistenceError.missingIdentityKey {
            guard createIfMissing else {
                throw TicketWorkflowPersistenceError.missingIdentityKey
            }
            return try mintAndStoreSecret()
        }
    }

    /// Returns the existing secret without creating one. `nil` if absent.
    func existingInstallationSecret() async throws -> Data? {
        do {
            return try readSecret()
        } catch TicketWorkflowPersistenceError.missingIdentityKey {
            return nil
        }
    }

    /// Whether an installation secret is already present (does not create).
    func hasInstallationSecret() async throws -> Bool {
        try await existingInstallationSecret() != nil
    }

    /// Deletes the installation secret. Used only after an explicit recovery choice.
    func deleteInstallationSecret() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw TicketWorkflowPersistenceError.keychainUnavailable
        default:
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
    }

    /// Mints a new secret after explicit recovery (replaces any existing item).
    func replaceInstallationSecret() async throws -> Data {
        try await deleteInstallationSecret()
        return try mintAndStoreSecret()
    }

    // MARK: - Private

    private func readSecret() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw TicketWorkflowPersistenceError.missingIdentityKey
            }
            return data
        case errSecItemNotFound:
            throw TicketWorkflowPersistenceError.missingIdentityKey
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw TicketWorkflowPersistenceError.keychainUnavailable
        default:
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
    }

    private func mintAndStoreSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.secretByteCount)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
        let secret = Data(bytes)
        try storeSecret(secret)
        return secret
    }

    private func storeSecret(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw mapStoreFailure(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw mapStoreFailure(status)
        }
    }

    private func mapStoreFailure(_ status: OSStatus) -> TicketWorkflowPersistenceError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .keychainUnavailable
        default:
            return .keychainUnavailable
        }
    }
}
