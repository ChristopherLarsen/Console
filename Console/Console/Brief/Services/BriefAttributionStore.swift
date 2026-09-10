import Foundation

/// Persists Morning Brief author identity selections. Folder paths are
/// already stored with workspaces; this store keeps only workspace UUIDs,
/// display names, and emails.
@MainActor
@Observable
final class BriefAttributionStore {
    private(set) var selectionsByWorkspaceID: [UUID: BriefWorkspaceAuthorSelection] = [:]

    private let defaults: UserDefaults

    private enum Key {
        static let payload = "briefAttribution.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.payload),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            selectionsByWorkspaceID = snapshot.selections.reduce(into: [:]) { result, selection in
                result[selection.workspaceID] = selection
            }
        }
    }

    func selection(for workspaceID: UUID) -> BriefWorkspaceAuthorSelection? {
        selectionsByWorkspaceID[workspaceID]
    }

    /// Records a Git-config default without marking it confirmed.
    func recordDefault(_ identity: BriefAuthorIdentity, for workspaceID: UUID) {
        guard identity.isUsable else { return }
        if let existing = selectionsByWorkspaceID[workspaceID], existing.identity.isUsable {
            return
        }
        selectionsByWorkspaceID[workspaceID] = BriefWorkspaceAuthorSelection(
            workspaceID: workspaceID,
            identity: identity,
            confirmed: false
        )
        persist()
    }

    func setIdentity(_ identity: BriefAuthorIdentity,
                     for workspaceID: UUID,
                     confirmed: Bool) {
        selectionsByWorkspaceID[workspaceID] = BriefWorkspaceAuthorSelection(
            workspaceID: workspaceID,
            identity: identity,
            confirmed: confirmed
        )
        persist()
    }

    /// Builds collection sources, filling missing identities from Git config.
    func sources(
        for workspaces: [BriefWorkspaceSnapshot],
        probing identityReader: (any BriefIdentityReading)?
    ) async -> [BriefCollectionSource] {
        var sources: [BriefCollectionSource] = []
        for workspace in workspaces {
            var identity = selectionsByWorkspaceID[workspace.id]?.identity ?? BriefAuthorIdentity()
            if !identity.isUsable, let identityReader {
                let probed = await identityReader.readConfiguredIdentity(at: workspace.directoryPath)
                if probed.isUsable {
                    recordDefault(probed, for: workspace.id)
                    identity = probed
                }
            }
            sources.append(
                BriefCollectionSource(
                    workspaceID: workspace.id,
                    path: workspace.directoryPath,
                    displayName: workspace.name,
                    identity: identity
                )
            )
        }
        return sources
    }

    private struct Snapshot: Codable {
        var selections: [BriefWorkspaceAuthorSelection]
    }

    private func persist() {
        let snapshot = Snapshot(
            selections: Array(selectionsByWorkspaceID.values)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Key.payload)
        }
    }
}
