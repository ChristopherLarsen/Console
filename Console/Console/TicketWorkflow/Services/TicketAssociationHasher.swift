import Foundation
import CryptoKit

/// Opaque ticket association. Package B owns Keychain-backed secret provision;
/// this helper is pure HMAC over normalized origin + issue key.
enum TicketAssociationHasher {
    static func normalizeOriginHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizeIssueKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Domain-separated HMAC-SHA256. Output digest only — never store inputs.
    static func token(
        originHost: String,
        issueKey: String,
        secret: Data
    ) -> TicketAssociationToken {
        let host = normalizeOriginHost(originHost)
        let key = normalizeIssueKey(issueKey)
        var payload = Data(TicketAssociationDomain.hmacDomain.utf8)
        payload.append(0)
        payload.append(Data(host.utf8))
        payload.append(0)
        payload.append(Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: secret))
        return TicketAssociationToken(digest: Data(mac))
    }
}
