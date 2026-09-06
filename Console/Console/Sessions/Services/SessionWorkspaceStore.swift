import CryptoKit
import Foundation

/// Persists user-configured workspace folders, defaults, last-used choices,
/// and opaque workspace-routing associations through UserDefaults.
///
/// Privacy boundary: only folder names/paths the user picked themselves,
/// UUIDs, and SHA-256 hashes of normalized routing identities are persisted.
/// Ticket titles, MR titles, source URLs, and raw project identifiers are
/// never stored.
@MainActor
@Observable
final class SessionWorkspaceStore {
    private(set) var workspaces: [SessionWorkspace] = []
    private(set) var defaultWorkspaceID: UUID?

    private var lastUsedByPurpose: [String: UUID] = [:]
    private var associationsByHash: [String: UUID] = [:]

    private let defaults: UserDefaults

    private enum Key {
        static let workspaces = "sessionWorkspaces.list"
        static let defaultID = "sessionWorkspaces.defaultID"
        static func lastUsed(_ purpose: SessionPurpose) -> String { "sessionWorkspaces.lastUsed.\(purpose.rawValue)" }
        static let associations = "sessionWorkspaces.associations"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Queries

    var availableWorkspaces: [SessionWorkspace] {
        workspaces.filter { isAvailable($0) }
    }

    func workspace(withID id: UUID?) -> SessionWorkspace? {
        guard let id else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    /// A workspace is available while its folder still exists and is readable.
    /// Unavailable entries stay visible (Settings/chooser) but are ignored
    /// during resolution until repaired or removed.
    func isAvailable(_ workspace: SessionWorkspace) -> Bool {
        Self.isAccessibleDirectory(atPath: workspace.directoryPath)
    }

    static func isAccessibleDirectory(atPath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: path)
    }

    /// Review workspaces must be valid Git repositories; New Ticket,
    /// Existing Ticket, and General may use any accessible directory. No
    /// network access happens here.
    static func meetsRequirement(for workspace: SessionWorkspace?, purpose: SessionPurpose) -> Bool {
        guard let workspace, isAccessibleDirectory(atPath: workspace.directoryPath) else { return false }
        switch purpose {
        case .review:
            return isGitRepository(atPath: workspace.directoryPath)
        case .newTicket, .existingTicket, .general:
            return true
        }
    }

    static func isGitRepository(atPath path: String) -> Bool {
        let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit.path)
    }

    /// Saved folders usable for a purpose, in saved order.
    func resolvableWorkspaces(purpose: SessionPurpose) -> [SessionWorkspace] {
        availableWorkspaces.filter { Self.meetsRequirement(for: $0, purpose: purpose) }
    }

    /// True when the session directory lives inside the workspace folder.
    static func contains(_ workspace: SessionWorkspace, directory: URL) -> Bool {
        let candidate = directory.standardizedFileURL.path
        return candidate == workspace.directoryPath || candidate.hasPrefix(workspace.directoryPath + "/")
    }

    // MARK: - Mutation

    /// Adds a workspace for a chosen folder. The first workspace ever added
    /// becomes the default automatically. Adding an existing folder again is
    /// a no-op returning the saved entry.
    @discardableResult
    func add(name: String, directoryURL: URL) -> SessionWorkspace {
        let path = directoryURL.standardizedFileURL.path
        if let existing = workspaces.first(where: { $0.directoryPath == path }) {
            return existing
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? "/" : trimmedName
        let workspace = SessionWorkspace(
            name: uniquedName(baseName),
            directoryPath: path
        )
        workspaces.append(workspace)
        if defaultWorkspaceID == nil {
            defaultWorkspaceID = workspace.id
        }
        persist()
        return workspace
    }

    private func uniquedName(_ base: String) -> String {
        let taken = Set(workspaces.map(\.name))
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !trimmed.isEmpty else {
            return
        }
        workspaces[index].name = trimmed
        persist()
    }

    func setDefault(id: UUID?) {
        guard let id, workspaces.contains(where: { $0.id == id }) else {
            defaultWorkspaceID = nil
            persist()
            return
        }
        defaultWorkspaceID = id
        persist()
    }

    /// Removes a workspace plus everything learned about it: the default
    /// marker, per-purpose last-used entries, and routing associations. The
    /// folder itself is never touched.
    func remove(id: UUID) {
        workspaces.removeAll(where: { $0.id == id })
        if defaultWorkspaceID == id {
            defaultWorkspaceID = nil
        }
        lastUsedByPurpose = lastUsedByPurpose.filter { $0.value != id }
        associationsByHash = associationsByHash.filter { $0.value != id }
        persist()
    }

    // MARK: - Last used per purpose

    func lastUsedWorkspaceID(for purpose: SessionPurpose) -> UUID? {
        lastUsedByPurpose[purpose.rawValue]
    }

    func noteUse(workspaceID: UUID, purpose: SessionPurpose) {
        lastUsedByPurpose[purpose.rawValue] = workspaceID
        persist()
    }

    // MARK: - Learned routing associations

    /// Opaque lookup: SHA-256(normalized routing identity) → workspace UUID.
    func associatedWorkspaceID(forRoutingIdentity identity: String) -> UUID? {
        associationsByHash[Self.routingHash(identity)]
    }

    func rememberAssociation(routingIdentity: String, workspaceID: UUID) {
        associationsByHash[Self.routingHash(routingIdentity)] = workspaceID
        persist()
    }

    var associationCount: Int { associationsByHash.count }

    /// Clears learned routing without removing workspaces, defaults, or
    /// last-used choices.
    func clearLearnedAssociations() {
        associationsByHash.removeAll()
        persist()
    }

    static func routingHash(_ identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: Key.workspaces),
           let decoded = try? JSONDecoder().decode([SessionWorkspace].self, from: data) {
            workspaces = decoded
        }
        if let idString = defaults.string(forKey: Key.defaultID) {
            defaultWorkspaceID = UUID(uuidString: idString)
        }
        for purpose in SessionPurpose.allCases {
            if let idString = defaults.string(forKey: Key.lastUsed(purpose)) {
                lastUsedByPurpose[purpose.rawValue] = UUID(uuidString: idString)
            }
        }
        if let stored = defaults.dictionary(forKey: Key.associations) as? [String: String] {
            associationsByHash = stored.compactMapValues(UUID.init(uuidString:))
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(workspaces) {
            defaults.set(data, forKey: Key.workspaces)
        }
        if let id = defaultWorkspaceID {
            defaults.set(id.uuidString, forKey: Key.defaultID)
        } else {
            defaults.removeObject(forKey: Key.defaultID)
        }
        for purpose in SessionPurpose.allCases {
            let key = Key.lastUsed(purpose)
            if let id = lastUsedByPurpose[purpose.rawValue] {
                defaults.set(id.uuidString, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(associationsByHash.mapValues(\.uuidString), forKey: Key.associations)
    }
}
