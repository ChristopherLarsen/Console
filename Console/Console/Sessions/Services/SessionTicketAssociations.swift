import Foundation

/// Persistent mapping from a Claude session ID to the ticket key Console
/// associated it with at launch. Written when a session is created from a
/// Jira source (or Console's `S-1234` new-ticket naming) and read by the
/// Previous Sessions history so classification survives Console restarts.
///
/// Local display data only — never sent to Claude.
struct SessionTicketAssociations {
    static let defaultsKey = "sessionTicketAssociations.byId"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func key(for claudeSessionID: UUID) -> String? {
        dictionary[claudeSessionID.uuidString]
    }

    /// Snapshot for off-main-actor classification lookups.
    func allKeys() -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (rawID, key) in dictionary {
            guard let id = UUID(uuidString: rawID) else { continue }
            result[id] = key
        }
        return result
    }

    func associate(_ key: String, with claudeSessionID: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = dictionary
        updated[claudeSessionID.uuidString] = trimmed
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    private var dictionary: [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}
