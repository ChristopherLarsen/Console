import Foundation

/// Long-lived work identity, independent of the list of currently open terminals.
/// Contains metadata only; Claude continues to own the transcripts.
@MainActor
final class SessionAssociationStore {
    struct Conversation: Codable, Identifiable {
        var id: UUID { record.id }
        var record: SessionRestorationRecord
        var artifacts: [SessionArtifact]
        var updatedAt: Date
    }
    private struct Snapshot: Codable {
        var version = 1
        var conversations: [Conversation] = []
        var preferredAuthors: [String: UUID] = [:]
    }
    private let url: URL?
    private var snapshot = Snapshot()
    private var loadFailed = false

    init(url: URL?) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 1,
                  Set(snapshot.conversations.map(\.id)).count == snapshot.conversations.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch { loadFailed = true }
    }

    static func mrIdentity(_ url: URL) -> String? {
        guard let source = MergeRequestSourceContext.launchSource(forURL: url, pageTitle: nil),
              case .mergeRequest(_, _, let canonical) = source else { return nil }
        var parts = URLComponents(url: canonical, resolvingAgainstBaseURL: false)
        let host = parts?.host?.lowercased()
        parts?.host = host
        parts?.query = nil
        parts?.fragment = nil
        return parts?.url?.absoluteString
    }

    func conversation(_ id: UUID) -> Conversation? {
        snapshot.conversations.first { $0.id == id }
    }

    func author(for url: URL) -> Conversation? {
        guard let key = Self.mrIdentity(url) else { return nil }
        if let id = snapshot.preferredAuthors[key], let known = conversation(id) { return known }
        let candidates = snapshot.conversations.filter { conversation in
            conversation.record.purpose != .review && conversation.artifacts.contains {
                $0.kind == .gitlabMergeRequest && $0.url.flatMap(Self.mrIdentity) == key
            }
        }
        // Ambiguous historical conversations require an explicit, remembered choice.
        return candidates.count == 1 ? candidates.first : nil
    }

    func remember(record: SessionRestorationRecord, artifacts: [SessionArtifact]) throws {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        var merged = conversation(record.id)?.artifacts ?? []
        for artifact in artifacts where !merged.contains(where: {
            $0.kind == artifact.kind && $0.url == artifact.url && $0.label == artifact.label
        }) { merged.append(artifact) }
        var localRecord = record
        localRecord.processIdentity = nil
        if let previous = conversation(record.id), previous.record == localRecord, previous.artifacts == merged { return }
        let previous = snapshot
        let value = Conversation(record: localRecord, artifacts: merged, updatedAt: Date())
        if let index = snapshot.conversations.firstIndex(where: { $0.id == record.id }) {
            snapshot.conversations[index] = value
        } else { snapshot.conversations.append(value) }
        do { try save() } catch { snapshot = previous; throw error }
    }

    func preferAuthor(_ id: UUID, for url: URL) throws {
        guard !loadFailed, conversation(id) != nil, let key = Self.mrIdentity(url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let previous = snapshot
        snapshot.preferredAuthors[key] = id
        do { try save() } catch { snapshot = previous; throw error }
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
