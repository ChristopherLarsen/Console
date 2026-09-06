import XCTest
@testable import Console

/// Local Git fixtures only: temporary repositories, linked worktrees, and
/// controlled author dates. No network.
@MainActor
final class BriefActivityCollectorTests: XCTestCase {

    private var tmpRoot: URL!
    private let collector = BriefActivityCollector()

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func dateInNewYork(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.date(from: string)!
    }

    // MARK: - Author filter

    func testCollectorReportsOnlyTheSelectedAuthor() async throws {
        let repo = try makeRepo(named: "Shared")
        try commit(
            in: repo,
            message: "Alice change",
            authorName: "Alice",
            authorEmail: "alice@example.test",
            date: "2026-09-04T12:00:00-04:00"
        )
        try commit(
            in: repo,
            message: "Bob change",
            authorName: "Bob",
            authorEmail: "bob@example.test",
            date: "2026-09-04T13:00:00-04:00"
        )

        let result = await collect(
            path: repo,
            displayName: "Shared",
            identity: BriefAuthorIdentity(name: "Alice", emails: ["alice@example.test"]),
            start: dateInNewYork("2026-09-04T00:00:00"),
            end: dateInNewYork("2026-09-05T00:00:00")
        )

        XCTAssertEqual(result.activities.map(\.subject), ["Alice change"])
        XCTAssertEqual(result.activities.map(\.authorEmail), ["alice@example.test"])
        XCTAssertEqual(result.sourceRepositories.map(\.displayName), ["Shared"])
    }

    func testCollectorSkipsSourcesWithoutASelectedIdentity() async throws {
        let repo = try makeRepo(named: "Unattributed")
        try commit(
            in: repo,
            message: "Anyone",
            authorName: "Bob",
            authorEmail: "bob@example.test",
            date: "2026-09-04T12:00:00-04:00"
        )

        let result = await collect(
            path: repo,
            displayName: "Unattributed",
            identity: BriefAuthorIdentity(),
            start: dateInNewYork("2026-09-04T00:00:00"),
            end: dateInNewYork("2026-09-05T00:00:00")
        )

        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.sourceRepositories.map(\.displayName), ["Unattributed"])
    }

    func testCollectorMatchesEmailAliases() async throws {
        let repo = try makeRepo(named: "AliasRepo")
        try commit(
            in: repo,
            message: "Personal laptop",
            authorName: "Alice",
            authorEmail: "alice@example.test",
            date: "2026-09-04T10:00:00-04:00"
        )
        try commit(
            in: repo,
            message: "Work laptop",
            authorName: "Alice",
            authorEmail: "alice.work@example.test",
            date: "2026-09-04T11:00:00-04:00"
        )
        try commit(
            in: repo,
            message: "Teammate",
            authorName: "Bob",
            authorEmail: "bob@example.test",
            date: "2026-09-04T12:00:00-04:00"
        )

        let result = await collect(
            path: repo,
            displayName: "AliasRepo",
            identity: BriefAuthorIdentity(
                name: "Alice",
                emails: ["alice@example.test", "alice.work@example.test"]
            ),
            start: dateInNewYork("2026-09-04T00:00:00"),
            end: dateInNewYork("2026-09-05T00:00:00")
        )

        XCTAssertEqual(Set(result.activities.map(\.subject)), ["Personal laptop", "Work laptop"])
    }

    // MARK: - Repository identity

    func testLinkedWorktreesDeduplicateTheSameCommit() async throws {
        let main = try makeRepo(named: "MainCheckout")
        let hash = try commit(
            in: main,
            message: "Shared work",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-04T15:00:00-04:00"
        )
        let linked = tmpRoot.appendingPathComponent("LinkedCheckout", isDirectory: true)
        try runGit(["worktree", "add", "--detach", "-q", linked.path], in: main)

        let identity = BriefAuthorIdentity(name: "Dev", emails: ["dev@example.test"])
        let start = dateInNewYork("2026-09-04T00:00:00")
        let end = dateInNewYork("2026-09-05T00:00:00")
        let result = await collector.collectActivities(
            BriefCollectionRequest(
                sources: [
                    BriefCollectionSource(
                        path: main.path,
                        displayName: "Main",
                        identity: identity
                    ),
                    BriefCollectionSource(
                        path: linked.path,
                        displayName: "Linked",
                        identity: identity
                    )
                ],
                rangeStart: start,
                rangeEnd: end,
                calendar: newYorkCalendar()
            )
        )

        XCTAssertEqual(result.activities.count, 1)
        XCTAssertEqual(result.activities.first?.commitHash, hash)
        XCTAssertEqual(result.sourceRepositories.count, 1)

        let mainIdentity = await collector.canonicalRepositoryIdentity(at: main.path)
        let linkedIdentity = await collector.canonicalRepositoryIdentity(at: linked.path)
        XCTAssertEqual(mainIdentity, linkedIdentity)
        XCTAssertNotNil(mainIdentity)
    }

    func testSameBasenameIndependentRepositoriesRemainDistinct() async throws {
        let one = try makeRepo(named: "repo-a/Console")
        let two = try makeRepo(named: "repo-b/Console")
        let hashOne = try commit(
            in: one,
            message: "Same subject",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-04T10:00:00-04:00"
        )
        let hashTwo = try commit(
            in: two,
            message: "Same subject",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-04T11:00:00-04:00"
        )
        XCTAssertNotEqual(hashOne, hashTwo)

        let identity = BriefAuthorIdentity(name: "Dev", emails: ["dev@example.test"])
        let result = await collector.collectActivities(
            BriefCollectionRequest(
                sources: [
                    BriefCollectionSource(path: one.path, displayName: "Console", identity: identity),
                    BriefCollectionSource(path: two.path, displayName: "Console", identity: identity)
                ],
                rangeStart: dateInNewYork("2026-09-04T00:00:00"),
                rangeEnd: dateInNewYork("2026-09-05T00:00:00"),
                calendar: newYorkCalendar()
            )
        )

        XCTAssertEqual(result.activities.count, 2)
        XCTAssertEqual(Set(result.activities.map(\.commitHash)), [hashOne, hashTwo])
        XCTAssertEqual(result.sourceRepositories.count, 2)
        XCTAssertNotEqual(
            result.sourceRepositories[0].identity,
            result.sourceRepositories[1].identity
        )
    }

    // MARK: - Calendar boundaries

    func testCollectorHonorsSelectedCalendarDayBoundaries() async throws {
        let repo = try makeRepo(named: "Boundary")
        try commit(
            in: repo,
            message: "Thursday late",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-04T23:59:00-04:00"
        )
        try commit(
            in: repo,
            message: "Friday start",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-05T00:00:00-04:00"
        )
        try commit(
            in: repo,
            message: "Friday late",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-05T23:59:00-04:00"
        )
        try commit(
            in: repo,
            message: "Saturday start",
            authorName: "Dev",
            authorEmail: "dev@example.test",
            date: "2026-09-06T00:00:00-04:00"
        )

        let result = await collect(
            path: repo,
            displayName: "Boundary",
            identity: BriefAuthorIdentity(name: "Dev", emails: ["dev@example.test"]),
            start: dateInNewYork("2026-09-05T00:00:00"),
            end: dateInNewYork("2026-09-06T00:00:00")
        )

        XCTAssertEqual(Set(result.activities.map(\.subject)), ["Friday start", "Friday late"])
    }

    func testConfiguredIdentityReadsLocalGitConfig() async throws {
        let repo = try makeRepo(named: "Configured")
        try runGit(["config", "user.name", "Configured Dev"], in: repo)
        try runGit(["config", "user.email", "configured@example.test"], in: repo)

        let identity = await collector.readConfiguredIdentity(at: repo.path)
        XCTAssertEqual(identity.name, "Configured Dev")
        XCTAssertEqual(identity.emails, ["configured@example.test"])
    }

    // MARK: - Fixtures

    private func collect(
        path: URL,
        displayName: String,
        identity: BriefAuthorIdentity,
        start: Date,
        end: Date
    ) async -> BriefCollectionResult {
        await collector.collectActivities(
            BriefCollectionRequest(
                sources: [
                    BriefCollectionSource(
                        path: path.path,
                        displayName: displayName,
                        identity: identity
                    )
                ],
                rangeStart: start,
                rangeEnd: end,
                calendar: newYorkCalendar()
            )
        )
    }

    private func makeRepo(named name: String) throws -> URL {
        let directory = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: directory)
        try runGit(["config", "user.name", "Fixture"], in: directory)
        try runGit(["config", "user.email", "fixture@example.test"], in: directory)
        return directory
    }

    @discardableResult
    private func commit(
        in directory: URL,
        message: String,
        authorName: String,
        authorEmail: String,
        date: String
    ) throws -> String {
        try runGit(
            ["commit", "--allow-empty", "-q", "-m", message],
            in: directory,
            extraEnvironment: [
                "GIT_AUTHOR_NAME": authorName,
                "GIT_AUTHOR_EMAIL": authorEmail,
                "GIT_AUTHOR_DATE": date,
                "GIT_COMMITTER_NAME": authorName,
                "GIT_COMMITTER_EMAIL": authorEmail,
                "GIT_COMMITTER_DATE": date
            ],
            extraGitConfig: [
                "user.name=\(authorName)",
                "user.email=\(authorEmail)"
            ]
        )
        return try runGit(["rev-parse", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct GitFixtureError: Error {}

    @discardableResult
    private func runGit(
        _ arguments: [String],
        in directory: URL,
        extraEnvironment: [String: String] = [:],
        extraGitConfig: [String] = []
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var gitArguments = [
            "-c", "commit.gpgsign=false",
            "-c", "init.defaultBranch=main"
        ]
        for config in extraGitConfig {
            gitArguments.append(contentsOf: ["-c", config])
        }
        gitArguments.append(contentsOf: arguments)
        process.arguments = gitArguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError()
        }
        return String(decoding: data, as: UTF8.self)
    }
}
