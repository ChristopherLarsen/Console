import XCTest
@testable import Console

/// Retention policy for Console-owned headless Claude transcripts: bounded
/// rotation of session records, and pruning of only the transcript files
/// whose names are exactly an owned session ID.
final class ClaudeOwnedSessionRetentionTests: XCTestCase {

    private var tempDirectory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeOwnedSessionRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ClaudeOwnedSessionRetentionTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testRegistryEvictsOldestBeyondLimit() {
        var registry = ClaudeOwnedSessionRegistry()
        let ids = (0..<5).map { _ in UUID() }
        ids.forEach { registry.record($0) }
        registry.record(ids[2]) // duplicate is a no-op
        XCTAssertEqual(registry.sessionIDs.count, 5)

        let evicted = registry.evictions(limit: 2)
        XCTAssertEqual(evicted, Array(ids.prefix(3)))
        registry.remove(evicted)
        XCTAssertEqual(registry.sessionIDs, Array(ids.suffix(2)))
    }

    func testTranscriptURLsMatchOnlyOwnedSessionIDsUnderProjectSlug() {
        let workingDirectory = "/Users/dev/Library/Application Support/Console/ManagedClaude/workspace"
        let ids = [UUID(), UUID()]
        let urls = ClaudeTranscriptRetention.transcriptURLs(
            sessionIDs: ids,
            workingDirectory: workingDirectory,
            claudeHomePath: tempDirectory.path
        )
        XCTAssertEqual(urls.count, 2)
        // The slug replaces path separators and underscores only; spaces are
        // retained by Claude Code's project-folder naming.
        XCTAssertEqual(urls.count, 2)
        for url in urls {
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                           "-Users-dev-Library-Application Support-Console-ManagedClaude-workspace")
        }
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ids.map { $0.uuidString + ".jsonl" })
    }

    func testPruneDeletesOnlyOwnedTranscripts() throws {
        let workingDirectory = tempDirectory.appending(path: "workspace").path
        let slug = ClaudeTranscriptRetention.projectSlug(forWorkingDirectory: workingDirectory)
        let projectFolder = tempDirectory
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

        let owned = UUID()
        let other = UUID()
        try Data("{}".utf8).write(to: projectFolder.appendingPathComponent(owned.uuidString + ".jsonl"))
        try Data("{}".utf8).write(to: projectFolder.appendingPathComponent(other.uuidString + ".jsonl"))
        try Data("{}".utf8).write(to: projectFolder.appendingPathComponent("unrelated-name.jsonl"))

        ClaudeTranscriptRetention.prune(
            evictedSessionIDs: [owned],
            workingDirectory: workingDirectory,
            claudeHomePath: tempDirectory.path
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: projectFolder.appendingPathComponent(owned.uuidString + ".jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFolder.appendingPathComponent(other.uuidString + ".jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFolder.appendingPathComponent("unrelated-name.jsonl").path))
    }

    func testOwnedSessionStoreRoundTrips() {
        let url = tempDirectory.appending(path: "owned-sessions.json")
        var registry = ClaudeOwnedSessionRegistry()
        let id = UUID()
        registry.record(id)
        ClaudeOwnedSessionStore.save(registry, url: url, fileManager: .default)

        let loaded = ClaudeOwnedSessionStore.load(url: url, fileManager: .default)
        XCTAssertEqual(loaded.sessionIDs, [id])
    }

    func testConfigurationPersistenceRoundTrips() {
        var configuration = ManagedClaudeConfiguration(
            model: "sonnet",
            maxTurns: 4,
            requestTimeout: 30,
            allowedTools: [],
            workingDirectoryPath: tempDirectory.path,
            maxRetainedSessions: 3
        )
        configuration.store(defaults: defaults)
        let loaded = ManagedClaudeConfiguration.load(defaults: defaults)
        XCTAssertEqual(loaded, configuration)
    }
}
