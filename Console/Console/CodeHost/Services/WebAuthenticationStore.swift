import Foundation
import Security
import WebKit
import OSLog

/// Browser-session cookies are not necessarily persisted by WebKit's disk store.
/// Keep a device-local Keychain snapshot; never change server-issued expiration.
@MainActor
final class WebAuthenticationStore: NSObject, WKHTTPCookieStoreObserver {
    static let shared = WebAuthenticationStore()
    let dataStore = WKWebsiteDataStore.default()
    private var restoration: Task<Void, Never>?
    private var saving = false
    private var needsSave = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Console", category: "WebAuthentication")

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Console") + ".web-session",
         kSecAttrAccount as String: "session-cookies"]
    }

    func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { @MainActor in
            var query = keychainQuery
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data,
               let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                let existing = await dataStore.httpCookieStore.allCookies()
                for row in rows {
                    let properties = Dictionary(uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) })
                    guard let cookie = HTTPCookie(properties: properties),
                          cookie.expiresDate.map({ $0 > Date() }) ?? true,
                          !existing.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path })
                    else { continue }
                    await dataStore.httpCookieStore.setCookie(cookie)
                }
            } else if status != errSecItemNotFound && status != errSecSuccess {
                logger.error("Cookie restoration failed: \(status)")
            }
            dataStore.httpCookieStore.add(self)
        }
        restoration = task
        await task.value
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.save() }
    }

    private func save() async {
        needsSave = true
        guard !saving else { return }
        saving = true
        defer { saving = false }
        repeat {
            needsSave = false
            let cookies = await dataStore.httpCookieStore.allCookies()
            let rows = cookies.filter(\.isSessionOnly).compactMap { cookie in
                cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
            }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0) else { return }
            let attributes: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = keychainQuery.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            if status != errSecSuccess { logger.error("Cookie persistence failed: \(status)") }
        } while needsSave
    }

    static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = shared.dataStore
        return WebPage(configuration: configuration, navigationDecider: SessionNavigationDecider())
    }

    private struct SessionNavigationDecider: WebPage.NavigationDeciding {
        func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
            await WebAuthenticationStore.shared.restore()
            return .allow
        }
    }
}
