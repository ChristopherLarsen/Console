import Foundation

/// Local launch metadata only. Conversations remain in Claude's own storage.
struct SessionRestorationRecord: Codable, Equatable, Identifiable {
    var id: UUID { claudeSessionID }
    let claudeSessionID: UUID
    var name: String
    var workingDirectory: URL
    let purpose: SessionPurpose
}

struct SessionRestorationSnapshot: Codable, Equatable {
    var version = 1
    var sessions: [SessionRestorationRecord] = []
    var selectedClaudeSessionID: UUID?
}

struct SessionRestorationStore {
    let url: URL

    static var standard: Self {
        Self(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Console/SessionRestoration.json"))
    }

    func load() throws -> SessionRestorationSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let snapshot = try JSONDecoder().decode(SessionRestorationSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1,
              Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }

    func save(_ snapshot: SessionRestorationSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
