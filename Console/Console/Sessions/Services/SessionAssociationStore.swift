import Foundation
import Observation

/// Single durable catalog for work, external artifacts, and Claude conversations.
/// Runtime terminals and Claude transcripts continue to have their own owners.
@MainActor
@Observable
final class SessionAssociationStore {
    struct Conversation: Codable, Identifiable {
        var id: UUID { record.id }
        var record: SessionRestorationRecord
        /// Read projection. Version 1 persisted these directly; version 2 stores
        /// artifacts on work items and keeps only conversation metadata here.
        var artifacts: [SessionArtifact]
        var updatedAt: Date
    }

    private struct Snapshot: Codable {
        var version = 2
        var conversations: [Conversation] = []
        var preferredAuthors: [String: UUID] = [:]
        var workItems: [WorkItem] = []
        var importedLegacyTickets = false

        enum CodingKeys: String, CodingKey { case version, conversations, preferredAuthors, workItems, importedLegacyTickets }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            conversations = try values.decode([Conversation].self, forKey: .conversations)
            preferredAuthors = try values.decode([String: UUID].self, forKey: .preferredAuthors)
            if version == 2 {
                workItems = try values.decode([WorkItem].self, forKey: .workItems)
                importedLegacyTickets = try values.decode(Bool.self, forKey: .importedLegacyTickets)
            }
        }
    }

    private let url: URL?
    private var snapshot = Snapshot()
    private(set) var persistenceError: String?
    private var loadFailed = false
    var workItems: [WorkItem] { snapshot.workItems }

    init(url: URL?, legacyTickets: [UUID: String] = [:]) {
        self.url = url
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
                guard [1, 2].contains(snapshot.version),
                      Set(snapshot.conversations.map(\.id)).count == snapshot.conversations.count,
                      Set(snapshot.workItems.map(\.id)).count == snapshot.workItems.count,
                      snapshot.workItems.allSatisfy({ work in
                          Set(work.sessions.map(\.conversationID)).count == work.sessions.count
                              && work.artifacts.allSatisfy { $0.identity == WorkArtifact.identity(kind: $0.kind, url: $0.url) }
                      }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        } catch {
            loadFailed = true
            snapshot = Snapshot()
            persistenceError = "Saved work associations could not be read. The original file has been preserved."
            return
        }
        let needsMigration = snapshot.version == 1 || (!snapshot.importedLegacyTickets && !legacyTickets.isEmpty)
        if snapshot.version == 1 {
            for conversation in snapshot.conversations {
                // Only review/ticket purposes establish roles. A generic legacy
                // conversation with an MR chip is not proof of authorship.
                ingest(record: conversation.record, artifacts: conversation.artifacts)
            }
            for (key, id) in snapshot.preferredAuthors {
                if let url = URL(string: key), let canonical = Self.mrIdentity(url) {
                    snapshot.preferredAuthors.removeValue(forKey: key)
                    snapshot.preferredAuthors[canonical] = id
                    promoteAuthor(id, identity: canonical)
                }
            }
            snapshot.conversations = snapshot.conversations.map {
                Conversation(record: $0.record, artifacts: [], updatedAt: $0.updatedAt)
            }
            snapshot.version = 2
        }
        if !snapshot.importedLegacyTickets {
            for (id, key) in legacyTickets where ticketKeys()[id] == nil {
                let artifact = WorkArtifact(.init(kind: .jiraIssue, label: key))
                if let index = snapshot.workItems.firstIndex(where: { $0.sessions.contains { $0.conversationID == id } }) {
                    snapshot.workItems[index].artifacts.append(artifact)
                } else {
                    snapshot.workItems.append(.init(id: UUID(), kind: .unspecified, title: key,
                        artifacts: [artifact], sessions: [.init(conversationID: id, role: .related)]))
                }
            }
            snapshot.importedLegacyTickets = true
        }
        if needsMigration {
            do { try save() }
            catch { persistenceError = "Work association migration could not be saved. The original data has been preserved." }
        }
    }

    static func mrIdentity(_ url: URL) -> String? {
        WorkArtifact.identity(kind: .gitlabMergeRequest, url: url)
    }

    func conversation(_ id: UUID) -> Conversation? {
        guard var value = snapshot.conversations.first(where: { $0.id == id }) else { return nil }
        value.artifacts = artifacts(for: id)
        return value
    }

    func artifacts(for conversationID: UUID) -> [SessionArtifact] {
        var result: [WorkArtifact] = []
        for work in snapshot.workItems where work.sessions.contains(where: { $0.conversationID == conversationID }) {
            for artifact in work.artifacts where !result.contains(where: { $0.represents(artifact) }) { result.append(artifact) }
        }
        return result.map(\.chip)
    }

    func relatedArtifacts(to url: URL, kind: SessionArtifactKind, workKind: WorkItem.Kind) -> [SessionArtifact] {
        guard let identity = WorkArtifact.identity(kind: kind, url: url) else { return [] }
        var result: [WorkArtifact] = []
        for work in snapshot.workItems where work.kind == workKind
            && work.artifacts.contains(where: { $0.kind == kind && $0.identity == identity }) {
            for artifact in work.artifacts where !result.contains(where: { $0.represents(artifact) }) { result.append(artifact) }
        }
        return result.map(\.chip)
    }

    /// Display classification only. Ambiguous multiple tickets are not guessed.
    func ticketKeys() -> [UUID: String] {
        var keys: [UUID: Set<String>] = [:]
        for work in snapshot.workItems {
            let tickets = work.artifacts.compactMap(\.ticketKey)
            for link in work.sessions { keys[link.conversationID, default: []].formUnion(tickets) }
        }
        return keys.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    func conversationIDs(for url: URL, kind: SessionArtifactKind, role: WorkSessionLink.Role? = nil) -> Set<UUID> {
        guard let identity = WorkArtifact.identity(kind: kind, url: url) else { return [] }
        return Set(snapshot.workItems.filter { work in work.artifacts.contains { $0.identity == identity && $0.kind == kind } }
            .flatMap(\.sessions).filter { role == nil || $0.role == role }.map(\.conversationID))
    }

    func author(for url: URL) -> Conversation? {
        guard let identity = Self.mrIdentity(url) else { return nil }
        let ids = conversationIDs(for: url, kind: .gitlabMergeRequest, role: .author)
        if let preferred = snapshot.preferredAuthors[identity], ids.contains(preferred) { return conversation(preferred) }
        let candidates = ids.compactMap { conversation($0) }
        return candidates.count == 1 ? candidates.first : nil
    }

    func review(for url: URL) -> Conversation? {
        let candidates = reviewConversations(for: url)
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Every durable reviewer conversation linked to a merge request, newest
    /// first. Unlike `review(for:)` this never collapses an ambiguous set, so a
    /// card can still offer the most recently used session.
    func reviewConversations(for url: URL) -> [Conversation] {
        conversationIDs(for: url, kind: .gitlabMergeRequest, role: .reviewer)
            .compactMap { conversation($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Shared live-session selection policy: prefer a running conversation,
    /// then newest runtime entry. Durable ambiguity is handled by author/review.
    func session(for url: URL, kind: SessionArtifactKind, role: WorkSessionLink.Role? = nil,
                 in sessions: [ConsoleSession]) -> ConsoleSession? {
        let ids = conversationIDs(for: url, kind: kind, role: role)
        let candidates = sessions.reversed().filter { ids.contains($0.claudeSessionID) }
        if role == .author, let key = Self.mrIdentity(url), let preferred = snapshot.preferredAuthors[key],
           let chosen = candidates.first(where: { $0.claudeSessionID == preferred && $0.activity != .exited }) { return chosen }
        return candidates.first { $0.activity != .exited } ?? candidates.first
    }

    func remember(record: SessionRestorationRecord, artifacts: [SessionArtifact], authoredMR: URL? = nil) throws {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        let previous = snapshot
        var localRecord = record
        localRecord.processIdentity = nil
        ingest(record: localRecord, artifacts: artifacts, authoredMR: authoredMR)
        if let authoredMR, let identity = Self.mrIdentity(authoredMR) { snapshot.preferredAuthors[identity] = record.id }
        if persistenceError == nil,
           previous.conversations.first(where: { $0.id == record.id })?.record == localRecord,
           previous.workItems == snapshot.workItems, previous.preferredAuthors == snapshot.preferredAuthors { return }
        let value = Conversation(record: localRecord, artifacts: [], updatedAt: Date())
        if let index = snapshot.conversations.firstIndex(where: { $0.id == record.id }) { snapshot.conversations[index] = value }
        else { snapshot.conversations.append(value) }
        do { try save(); persistenceError = nil }
        catch { snapshot = previous; persistenceError = "Work associations could not be saved."; throw error }
    }

    func preferAuthor(_ id: UUID, for url: URL) throws {
        guard !loadFailed, let conversation = conversation(id),
              let key = Self.mrIdentity(url), conversation.artifacts.contains(where: { $0.url.flatMap(Self.mrIdentity) == key })
        else { throw CocoaError(.fileReadCorruptFile) }
        try remember(record: conversation.record, artifacts: conversation.artifacts, authoredMR: url)
    }

    private func promoteAuthor(_ id: UUID, identity: String) {
        for index in snapshot.workItems.indices where snapshot.workItems[index].kind != .review
            && snapshot.workItems[index].artifacts.contains(where: { $0.identity == identity }) {
            if let link = snapshot.workItems[index].sessions.firstIndex(where: { $0.conversationID == id }) {
                snapshot.workItems[index].sessions[link].role = .author
                snapshot.workItems[index].kind = .implementation
            }
        }
    }

    private func ingest(record: SessionRestorationRecord, artifacts: [SessionArtifact], authoredMR: URL? = nil) {
        let kind: WorkItem.Kind = authoredMR != nil ? .implementation
            : record.purpose == .review ? .review
            : [.existingTicket, .newTicket].contains(record.purpose) ? .implementation : .unspecified
        let role: WorkSessionLink.Role = kind == .review ? .reviewer : kind == .implementation ? .author : .related
        let authoredIdentity = authoredMR.flatMap(Self.mrIdentity)
        let existingWorks = snapshot.workItems.filter { $0.sessions.contains { $0.conversationID == record.id } }
        let sameRoleArtifacts = existingWorks.filter {
            $0.kind == kind || (kind == .unspecified && $0.kind == .implementation)
        }.flatMap(\.artifacts)
        let otherRoleArtifacts = existingWorks.filter {
            $0.kind != kind && !(kind == .unspecified && $0.kind == .implementation)
        }.flatMap(\.artifacts)
        let incoming = artifacts.map(WorkArtifact.init).filter { artifact in
            if let authoredIdentity, artifact.kind == .gitlabMergeRequest { return artifact.identity == authoredIdentity }
            if authoredMR != nil { return true }
            // Chips are projections of all associated work. A metadata update
            // must not turn an author link into a review link (or vice versa).
            return sameRoleArtifacts.contains { $0.represents(artifact) }
                || !otherRoleArtifacts.contains { $0.represents(artifact) }
        }
        let primary = kind == .review ? incoming.filter { $0.kind == .gitlabMergeRequest }
            : incoming.filter { $0.kind == .jiraIssue }
        let anchors = primary.isEmpty ? incoming.filter { $0.kind == .gitlabMergeRequest } : primary
        // Join only one unambiguous, fully scoped work identity. In particular,
        // bare ticket keys and co-occurring links never merge unrelated work.
        let anchor = anchors.count == 1 ? anchors.first?.identity : nil
        let existing = snapshot.workItems.firstIndex { work in
            (work.kind == kind || (work.kind == .unspecified && kind != .review)
                || (kind == .unspecified && work.kind == .implementation))
                && work.sessions.contains { $0.conversationID == record.id }
        }
        let matching = anchor.flatMap { key in
            let candidates = snapshot.workItems.indices.filter {
                snapshot.workItems[$0].kind == kind && snapshot.workItems[$0].artifacts.contains { $0.identity == key }
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        let index: Int
        if let known = existing ?? matching { index = known }
        else {
            index = snapshot.workItems.count
            snapshot.workItems.append(.init(id: UUID(), kind: kind, title: record.name, artifacts: [], sessions: []))
        }
        if snapshot.workItems[index].kind == .unspecified { snapshot.workItems[index].kind = kind }
        if let link = snapshot.workItems[index].sessions.firstIndex(where: { $0.conversationID == record.id }) {
            if role != .related { snapshot.workItems[index].sessions[link].role = role }
        } else { snapshot.workItems[index].sessions.append(.init(conversationID: record.id, role: role)) }
        for artifact in incoming {
            if let known = snapshot.workItems[index].artifacts.firstIndex(where: { $0.represents(artifact) }) {
                snapshot.workItems[index].artifacts[known].label = artifact.label
            } else { snapshot.workItems[index].artifacts.append(artifact) }
        }
        // A later explicit URL may resolve a key-only chip within this work.
        // Do not resolve it if the work names that key on two different sites.
        let scopedTickets = snapshot.workItems[index].artifacts.filter { $0.kind == .jiraIssue && $0.identity != nil }
        snapshot.workItems[index].artifacts.removeAll { artifact in
            artifact.kind == .jiraIssue && artifact.identity == nil && artifact.ticketKey != nil
                && scopedTickets.filter { $0.ticketKey == artifact.ticketKey }.count == 1
        }
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
