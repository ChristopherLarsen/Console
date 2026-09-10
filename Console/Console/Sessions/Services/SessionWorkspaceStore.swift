import CryptoKit
import Foundation

/// Single-folder workspace store.
///
/// Console works on exactly one workspace: the Session Folder chosen in
/// Settings → Claude. Claude sessions always start there. This type is now a
/// thin compatibility adapter that exposes that one folder as a
/// `SessionWorkspace` (stable UUID) so Morning Brief and the iOS build
/// profiles keep their workspace-ID contracts.
///
/// Privacy boundary: only the folder path the user picked themselves and a
/// UUID are persisted. Ticket titles, MR titles, and source URLs are never
/// stored.
@MainActor
@Observable
final class SessionWorkspaceStore {
    /// Authoritative setting. Empty means unset.
    private(set) var defaultFolderPath: String = ""

    /// Zero or one entry: the configured Session Folder while it exists.
    private(set) var workspaces: [SessionWorkspace] = []
    private(set) var defaultWorkspaceID: UUID?

    private let defaults: UserDefaults

    private enum Key {
        static let folderPath = "sessions.defaultFolderPath"
        static let folderWorkspaceID = "sessions.defaultFolderWorkspaceID"
        static let migrated = "sessionWorkspaces.migratedToDefaultFolder"
        static let workspaces = "sessionWorkspaces.list"
        static let defaultID = "sessionWorkspaces.defaultID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyDataIfNeeded()
        load()
    }

    // MARK: - Queries

    /// The configured Session Folder entry, or nil when unset. Availability
    /// (folder exists and is readable) is checked separately.
    var defaultFolder: SessionWorkspace? {
        workspaces.first
    }

    var availableWorkspaces: [SessionWorkspace] {
        workspaces.filter { isAvailable($0) }
    }

    func workspace(withID id: UUID?) -> SessionWorkspace? {
        guard let id else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    /// A workspace is available while its folder still exists and is readable.
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

    /// Review launches require the folder to be a valid Git repository.
    /// No network access happens here.
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

    // MARK: - Mutation

    /// Sets (or clears) the single Session Folder. A stable UUID is kept for
    /// the same canonical path so iOS build profiles survive a restart; a
    /// different folder gets a fresh identity, which orphans its profiles.
    func setDefaultFolderPath(_ rawPath: String?) {
        guard let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaultFolderPath = ""
            workspaces = []
            defaultWorkspaceID = nil
            persist()
            return
        }
        let path = CheckoutPath.canonical(URL(fileURLWithPath: rawPath, isDirectory: true))
        let existing = workspaces.first
        if let existing, existing.directoryPath == path {
            defaultFolderPath = path
            persist()
            return
        }
        let workspace = SessionWorkspace(
            id: defaultWorkspaceIDForNewFolder(at: path),
            name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent,
            directoryPath: path
        )
        workspaces = [workspace]
        defaultWorkspaceID = workspace.id
        defaultFolderPath = path
        persist()
    }

    /// Same canonical path re-chosen keeps its identity; anything else gets a
    /// fresh one.
    private func defaultWorkspaceIDForNewFolder(at path: String) -> UUID {
        if let existing = workspaces.first, existing.directoryPath == path {
            return existing.id
        }
        return UUID()
    }

    // MARK: - Migration + persistence

    private func load() {
        if let path = defaults.string(forKey: Key.folderPath) {
            defaultFolderPath = path
            let id = (defaults.string(forKey: Key.folderWorkspaceID)).flatMap(UUID.init(uuidString:)) ?? UUID()
            if Self.isAccessibleDirectory(atPath: path) {
                let workspace = SessionWorkspace(
                    id: id,
                    name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent,
                    directoryPath: path
                )
                workspaces = [workspace]
                defaultWorkspaceID = workspace.id
            }
        }
    }

    /// One-time adoption of the previous default workspace (or the sole
    /// legacy entry) as the Session Folder. Ambiguous legacy data (several
    /// folders, no default) is left unset rather than guessed. Legacy keys
    /// are always removed, and never re-imported after the user clears the
    /// folder.
    private func migrateLegacyDataIfNeeded() {
        guard defaults.object(forKey: Key.migrated) == nil else { return }
        defer { defaults.set(true, forKey: Key.migrated) }

        guard defaults.string(forKey: Key.folderPath) == nil else {
            clearLegacyData()
            return
        }
        guard let data = defaults.data(forKey: "sessionWorkspaces.list"),
              let legacy = try? JSONDecoder().decode([SessionWorkspace].self, from: data),
              !legacy.isEmpty
        else {
            clearLegacyData()
            return
        }

        let defaultID = defaults.string(forKey: "sessionWorkspaces.defaultID").flatMap(UUID.init(uuidString:))
        let candidates = defaultID.flatMap { id in legacy.first(where: { $0.id == id }) }.map { [$0] } ?? legacy
        guard candidates.count == 1, let chosen = candidates.first else {
            clearLegacyData()
            return
        }

        defaultFolderPath = chosen.directoryPath
        defaultWorkspaceID = chosen.id
        workspaces = [chosen]
        defaults.set(chosen.directoryPath, forKey: Key.folderPath)
        defaults.set(chosen.id.uuidString, forKey: Key.folderWorkspaceID)
        clearLegacyData()
    }

    private func clearLegacyData() {
        defaults.removeObject(forKey: "sessionWorkspaces.list")
        defaults.removeObject(forKey: "sessionWorkspaces.defaultID")
        defaults.removeObject(forKey: "sessionWorkspaces.associations")
        for purpose in SessionPurpose.allCases {
            defaults.removeObject(forKey: "sessionWorkspaces.lastUsed.\(purpose.rawValue)")
        }
    }

    private func persist() {
        if defaultFolderPath.isEmpty {
            defaults.removeObject(forKey: Key.folderPath)
            defaults.removeObject(forKey: Key.folderWorkspaceID)
        } else {
            defaults.set(defaultFolderPath, forKey: Key.folderPath)
            if let id = defaultWorkspaceID {
                defaults.set(id.uuidString, forKey: Key.folderWorkspaceID)
            }
        }
    }
}
