import Foundation

/// Persists per-workspace `IOSProjectProfile` values through UserDefaults.
/// Stores only user-selected local configuration — never signing material
/// or source content. A failed discovery must call `applyRefresh` with a
/// repair outcome that leaves a previously valid profile intact.
@MainActor
@Observable
final class IOSProjectProfileStore {
    nonisolated static let storageKey = "iosProjectProfiles.byWorkspaceID"
    nonisolated static let currentSchemaVersion = 1

    private(set) var profilesByWorkspaceID: [UUID: IOSProjectProfile] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func profile(for workspaceID: UUID) -> IOSProjectProfile? {
        profilesByWorkspaceID[workspaceID]
    }

    func profileOrEmpty(for workspaceID: UUID) -> IOSProjectProfile {
        profilesByWorkspaceID[workspaceID] ?? .empty(workspaceID: workspaceID)
    }

    func save(_ profile: IOSProjectProfile) {
        let normalized = profile.normalized()
        profilesByWorkspaceID[normalized.workspaceID] = normalized
        persist()
    }

    /// Writes the repaired profile only when discovery actually filled an
    /// empty field. Failed lookups produce `didChangeProfile == false`.
    func applyRefresh(_ result: IOSDiscoveryRefreshResult) {
        guard result.repair.didChangeProfile else { return }
        save(result.repair.profile)
    }

    func removeProfile(for workspaceID: UUID) {
        profilesByWorkspaceID.removeValue(forKey: workspaceID)
        persist()
    }

    func retainOnly(workspaceIDs: Set<UUID>) {
        let before = profilesByWorkspaceID
        profilesByWorkspaceID = profilesByWorkspaceID.filter { workspaceIDs.contains($0.key) }
        if profilesByWorkspaceID != before {
            persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            profilesByWorkspaceID = Dictionary(
                uniqueKeysWithValues: payload.profiles.map { ($0.workspaceID, $0.normalized()) }
            )
            persist()
            return
        }
        if let legacy = try? JSONDecoder().decode([IOSProjectProfile].self, from: data) {
            profilesByWorkspaceID = Dictionary(
                uniqueKeysWithValues: legacy.map { ($0.workspaceID, $0.normalized()) }
            )
            persist()
        }
    }

    private func persist() {
        let payload = Payload(
            schemaVersion: Self.currentSchemaVersion,
            profiles: profilesByWorkspaceID.values.sorted {
                $0.workspaceID.uuidString < $1.workspaceID.uuidString
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    struct Payload: Codable, Equatable {
        var schemaVersion: Int
        var profiles: [IOSProjectProfile]

        init(schemaVersion: Int, profiles: [IOSProjectProfile]) {
            self.schemaVersion = schemaVersion
            self.profiles = profiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            profiles = try container.decodeIfPresent([IOSProjectProfile].self, forKey: .profiles) ?? []
        }
    }
}
