import Foundation

/// Registry of Claude session IDs this service explicitly created via
/// `--session-id`. The registry is the only resume identity source: `--resume`
/// is only ever issued for an ID recorded here, and `--continue` (latest
/// conversation) is never used.
struct ClaudeOwnedSessionRegistry: Equatable, Codable, Sendable {
    /// Oldest first. New owned sessions append; eviction is bounded rotation
    /// from the front.
    private(set) var sessionIDs: [UUID] = []

    mutating func record(_ id: UUID) {
        guard !sessionIDs.contains(id) else { return }
        sessionIDs.append(id)
    }

    /// Sessions beyond the retention limit, oldest first.
    func evictions(limit: Int) -> [UUID] {
        guard sessionIDs.count > limit else { return [] }
        return Array(sessionIDs.prefix(sessionIDs.count - limit))
    }

    mutating func remove(_ ids: [UUID]) {
        let doomed = Set(ids)
        sessionIDs.removeAll { doomed.contains($0) }
    }
}

/// Retention policy for Claude transcripts of owned sessions.
///
/// Claude Code persists headless-run transcripts under
/// `~/.claude/projects/<slug-of-cwd>/<session-id>.jsonl` regardless of how the
/// CLI was launched, so Console cannot assume its own logging settings govern
/// that persistence. This pruner is the explicit, bounded policy: only files
/// whose names match owned session IDs, only under the managed working
/// directory's project folder, best effort, never throwing.
enum ClaudeTranscriptRetention {
    /// Slug Claude Code uses for project folders derived from a cwd.
    static func projectSlug(forWorkingDirectory workingDirectory: String) -> String {
        workingDirectory
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    static func projectsRoot(claudeHomePath: String = "~/") -> URL {
        let expanded = (claudeHomePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Candidate transcript files for the given owned session IDs. Only file
    /// names that are exactly an owned session ID are ever returned.
    static func transcriptURLs(
        sessionIDs: [UUID],
        workingDirectory: String,
        claudeHomePath: String = "~/"
    ) -> [URL] {
        let folder = projectsRoot(claudeHomePath: claudeHomePath)
            .appendingPathComponent(projectSlug(forWorkingDirectory: workingDirectory), isDirectory: true)
        return sessionIDs.map { folder.appendingPathComponent($0.uuidString + ".jsonl") }
    }

    /// Deletes transcripts of evicted owned sessions. Best effort; failures
    /// are silent because retention is not a security mechanism — it is
    /// bounded hygiene for Console-owned runs.
    static func prune(
        evictedSessionIDs: [UUID],
        workingDirectory: String,
        claudeHomePath: String = "~/",
        fileManager: FileManager = .default
    ) {
        guard !evictedSessionIDs.isEmpty else { return }
        for url in transcriptURLs(sessionIDs: evictedSessionIDs, workingDirectory: workingDirectory, claudeHomePath: claudeHomePath) {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

/// Loads and persists the owned-session registry JSON under Console's
/// Application Support directory. Content is session UUIDs only.
enum ClaudeOwnedSessionStore {
    static func storageURL(
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL {
        let base = applicationSupport ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Console/ManagedClaude", isDirectory: true)
            .appendingPathComponent("owned-sessions.json")
    }

    static func load(url: URL = storageURL(), fileManager: FileManager = .default) -> ClaudeOwnedSessionRegistry {
        guard let data = fileManager.contents(atPath: url.path),
              let registry = try? JSONDecoder().decode(ClaudeOwnedSessionRegistry.self, from: data) else {
            return ClaudeOwnedSessionRegistry()
        }
        return registry
    }

    static func save(_ registry: ClaudeOwnedSessionRegistry, url: URL = storageURL(), fileManager: FileManager = .default) {
        let folder = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(registry) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Serial gate

/// Cooperative serial gate: exactly one managed operation runs at a time per
/// service (per connection identity in v1 there is a single service).
final class ClaudeSerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isLocked = false

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !isLocked {
                isLocked = true
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            isLocked = false
            lock.unlock()
        }
    }

    /// True while an operation holds the gate.
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return isLocked
    }
}
