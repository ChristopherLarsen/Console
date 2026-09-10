import XCTest
@testable import Console

@MainActor
final class BriefStoreAndServiceTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: BriefStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-store-tests-\(UUID().uuidString)", isDirectory: true)
        store = BriefStore(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        store = nil
        tempDirectory = nil
        super.tearDown()
    }

    private let calendar = Calendar.current

    private func startOfDay(_ offset: Int, from reference: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference))!
    }

    private func activity(_ subject: String, on day: Date) -> CommitActivity {
        CommitActivity(repositoryName: "Repo", subject: subject, committedAt: day)
    }

    // MARK: - Persistence round trip

    func testSaveAndLoadRoundTripsBrief() throws {
        let day = startOfDay(0)
        var brief = BriefComposer.compose(
            day: day,
            activities: [CommitActivity(repositoryName: "Alpha", subject: "Did work", committedAt: day)]
        )
        brief.source = .ai
        brief.activityRangeStart = day
        brief.activityRangeEnd = calendar.date(byAdding: .day, value: 1, to: day)
        brief.sourceRepositoryNames = ["Alpha"]

        try store.save(brief)
        let loaded = try XCTUnwrap(store.load(forDay: day))

        XCTAssertEqual(loaded.day, brief.day)
        XCTAssertEqual(loaded.yesterdayLines, brief.yesterdayLines)
        XCTAssertEqual(loaded.source, .ai)
        XCTAssertEqual(loaded.activityRangeStart, brief.activityRangeStart)
        XCTAssertEqual(loaded.activityRangeEnd, brief.activityRangeEnd)
        XCTAssertEqual(loaded.sourceRepositoryNames, ["Alpha"])
    }

    /// Briefs persisted by older builds carry task fields the model no longer
    /// keeps; loading must succeed and simply ignore them.
    func testLoadIgnoresLegacyTaskFields() throws {
        let day = startOfDay(0)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "day": \(day.timeIntervalSince1970),
          "yesterdayLines": ["Alpha — Work"],
          "todayTasks": ["Old plan"],
          "generatedAt": \(Date().timeIntervalSince1970),
          "source": "local",
          "tasksManuallyEdited": true
        }
        """
        try Data(legacyJSON.utf8).write(to: store.url(forDay: day))

        let loaded = try XCTUnwrap(store.load(forDay: day))
        XCTAssertEqual(loaded.yesterdayLines, ["Alpha — Work"])
    }

    func testLoadMissingDayReturnsNil() {
        XCTAssertNil(store.load(forDay: startOfDay(-5)))
    }

    // MARK: - H38-F03: save failures must be surfaced, not silent

    func testSaveThrowsWhenDirectoryIsUnwritable() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let blocked = tempDirectory.appendingPathComponent("blocked", isDirectory: true)
        try Data("occupant".utf8).write(to: blocked)
        let store = BriefStore(directory: blocked)
        let brief = BriefComposer.compose(day: startOfDay(0), activities: [])
        XCTAssertThrowsError(try store.save(brief))
    }

    // MARK: - Generation service

    func testEnsureBriefGeneratesOnceThenServesStoredContent() async {
        let service = BriefGenerationService(store: store, collector: StubCollector(activityCount: 2))
        let today = startOfDay(0)

        let generated = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        XCTAssertEqual(generated.yesterdayLines.count, 2)

        // Second call must come from storage (the stub would return nothing
        // for empty paths if regeneration ran).
        let again = await service.ensureBrief(for: today, workspacePaths: [])
        XCTAssertEqual(again.yesterdayLines.count, 2)
        XCTAssertEqual(again.yesterdayLines, generated.yesterdayLines)
    }

    // MARK: - Previous-workday auto-detection

    func testAutoDetectionReportsMostRecentDayWithCommits() async {
        let service = BriefGenerationService(store: store, collector: LookbackCollector(days: [
            startOfDay(-1): [activity("Quiet Monday work", on: startOfDay(-1))],
            startOfDay(-4): [activity("Friday work", on: startOfDay(-4))],
            startOfDay(-5): [activity("Older work", on: startOfDay(-5))]
        ]))
        let today = startOfDay(0)

        let brief = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])

        XCTAssertEqual(brief.yesterdayLines, ["Repo — Quiet Monday work"])
        XCTAssertEqual(brief.activityRangeStart, startOfDay(-1))
        XCTAssertEqual(brief.activityRangeEnd, today)
    }

    func testAutoDetectionSkipsQuietWeekendsAndHolidays() async {
        // The stub returns commits only for Friday; the weekend days
        // in between carry nothing and must not become the report day.
        let service = BriefGenerationService(store: store, collector: LookbackCollector(days: [
            startOfDay(-3): [activity("Friday work", on: startOfDay(-3))]
        ]))
        let today = startOfDay(0)

        let brief = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        XCTAssertEqual(brief.yesterdayLines, ["Repo — Friday work"])
        XCTAssertEqual(brief.activityRangeStart, startOfDay(-3))
    }

    func testAutoDetectionFallsBackToQuietPreviousWeekday() async {
        let service = BriefGenerationService(store: store, collector: LookbackCollector(days: [:]))
        let today = startOfDay(0)

        let brief = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        XCTAssertEqual(brief.yesterdayLines, [BriefComposer.quietDayLine])
        let calendar = Calendar.current
        XCTAssertEqual(
            brief.activityRangeStart,
            BriefComposer.previousWeekday(before: today, calendar: calendar)
        )
    }

    func testExplicitWorkdayPickReportsExactlyThatDayEvenWhenQuiet() async {
        let service = BriefGenerationService(store: store, collector: LookbackCollector(days: [
            startOfDay(-1): [activity("Yesterday work", on: startOfDay(-1))]
        ]))
        let today = startOfDay(0)
        let picked = startOfDay(-5)

        let brief = await service.regenerate(for: today, workspacePaths: ["/tmp/Repo"], workday: picked)
        XCTAssertEqual(brief.yesterdayLines, [BriefComposer.quietDayLine], "a picked quiet day stays quiet")
        XCTAssertEqual(brief.activityRangeStart, picked)
        XCTAssertEqual(brief.activityRangeEnd, startOfDay(-4))
    }

    func testExplicitWorkdayPickReportsThatDaysWork() async {
        let service = BriefGenerationService(store: store, collector: LookbackCollector(days: [
            startOfDay(-1): [activity("Recent work", on: startOfDay(-1))],
            startOfDay(-6): [activity("Picked day work", on: startOfDay(-6))]
        ]))
        let today = startOfDay(0)
        let picked = startOfDay(-6)

        let brief = await service.regenerate(for: today, workspacePaths: ["/tmp/Repo"], workday: picked)
        XCTAssertEqual(brief.yesterdayLines, ["Repo — Picked day work"])
        XCTAssertEqual(brief.activityRangeStart, picked)
    }

    // MARK: - AI refinement

    func testApplyRefinementReplacesReportLines() async throws {
        let service = BriefGenerationService(store: store, collector: StubCollector(activityCount: 1))
        let today = startOfDay(0)

        let brief = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        let parsed = BriefAIResponseParser.Parsed(yesterdayLines: ["Polished line"])
        let refined = service.applyRefinement(parsed, to: brief)
        XCTAssertEqual(refined.yesterdayLines, ["Polished line"])
        XCTAssertEqual(refined.source, .ai)

        let refinedAgain = service.applyRefinement(
            BriefAIResponseParser.Parsed(yesterdayLines: ["Second polish"]),
            to: refined
        )
        XCTAssertEqual(refinedAgain.yesterdayLines, ["Second polish"])
    }

    func testRegenerateUsesChosenWorkdayAndRecordsSources() async throws {
        let collector = RecordingCollector(activityCount: 1)
        let service = BriefGenerationService(store: store, collector: collector)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let monday = calendar.startOfDay(for: dateInNewYork("2026-09-07T09:00:00"))
        let friday = calendar.startOfDay(for: dateInNewYork("2026-09-04T09:00:00"))
        let sources = [
            BriefCollectionSource(
                workspaceID: UUID(),
                path: "/tmp/Console",
                displayName: "Console",
                identity: BriefAuthorIdentity(name: "Dev", emails: ["dev@example.test"])
            )
        ]

        let brief = await service.regenerate(
            for: monday,
            sources: sources,
            calendar: calendar,
            workday: friday
        )

        let request = try XCTUnwrap(collector.lastRequest)
        XCTAssertEqual(request.rangeStart, friday)
        XCTAssertEqual(request.rangeEnd, calendar.date(byAdding: .day, value: 1, to: friday))
        XCTAssertEqual(brief.sourceRepositoryNames, ["Console"])
        XCTAssertEqual(brief.activityRangeStart, friday)
        XCTAssertEqual(brief.activityRangeEnd, calendar.date(byAdding: .day, value: 1, to: friday))
    }

    func testSupersededGenerationDoesNotWriteDisk() async throws {
        let collector = SuspendableActivityCollector(
            activities: [CommitActivity(repositoryName: "Repo", subject: "First collect", committedAt: startOfDay(-1))]
        )
        let service = BriefGenerationService(store: store, collector: collector)
        let today = startOfDay(0)
        try store.save(BriefComposer.compose(
            day: today,
            activities: [CommitActivity(repositoryName: "Repo", subject: "Stored work", committedAt: startOfDay(-2))]
        ))

        let firstToken = service.beginOperation(.generate, for: today)
        let first = Task {
            await service.regenerate(for: today, workspacePaths: ["/tmp/Repo"], token: firstToken)
        }
        await waitUntil { collector.pendingCount == 1 }

        collector.activities = [
            CommitActivity(repositoryName: "Repo", subject: "Second collect", committedAt: startOfDay(-1))
        ]
        let secondToken = service.beginOperation(.generate, for: today)
        let second = Task {
            await service.regenerate(for: today, workspacePaths: ["/tmp/Repo"], token: secondToken)
        }
        await waitUntil { collector.pendingCount == 2 }

        collector.releaseOldest()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .superseded)
        let afterFirst = try XCTUnwrap(store.load(forDay: today))
        XCTAssertFalse(afterFirst.yesterdayLines.contains(where: { $0.contains("First collect") }))

        collector.releaseOldest()
        let secondOutcome = await second.value
        guard case .applied(let regenerated) = secondOutcome else {
            return XCTFail("Expected the current generation to apply")
        }
        XCTAssertTrue(regenerated.yesterdayLines.contains(where: { $0.contains("Second collect") }))
    }

    func testCrossServiceOperationSupersedesSharedStoreWrite() async throws {
        // Bootstrap (ConsoleApp) and the Brief panel each construct their own
        // service over the same on-disk store. The panel's later operation
        // must supersede the bootstrap's in-flight generate.
        let collector = SuspendableActivityCollector(
            activities: [CommitActivity(repositoryName: "Repo", subject: "Bootstrap collect", committedAt: startOfDay(-1))]
        )
        let bootstrapService = BriefGenerationService(store: store, collector: collector)
        let panelService = BriefGenerationService(store: store, collector: collector)
        let today = startOfDay(0)

        let bootstrapToken = bootstrapService.beginOperation(.generate, for: today)
        let bootstrapTask = Task {
            await bootstrapService.regenerate(for: today, workspacePaths: ["/tmp/Repo"], token: bootstrapToken)
        }
        await waitUntil { collector.pendingCount == 1 }

        collector.activities = [
            CommitActivity(repositoryName: "Repo", subject: "Panel collect", committedAt: startOfDay(-1))
        ]
        let panelTask = Task {
            await panelService.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        }
        await waitUntil { collector.pendingCount == 2 }

        collector.releaseOldest()
        let bootstrapOutcome = await bootstrapTask.value
        XCTAssertEqual(bootstrapOutcome, .superseded)

        collector.releaseOldest()
        let panelBrief = await panelTask.value
        XCTAssertTrue(panelBrief.yesterdayLines.contains(where: { $0.contains("Panel collect") }))

        let onDisk = try XCTUnwrap(store.load(forDay: today))
        XCTAssertTrue(onDisk.yesterdayLines.contains(where: { $0.contains("Panel collect") }))
        XCTAssertFalse(onDisk.yesterdayLines.contains(where: { $0.contains("Bootstrap collect") }))
    }

    func testPreviousDayGenerationDoesNotReplaceTodaysStoredBrief() async throws {
        let collector = SuspendableActivityCollector(
            activities: [CommitActivity(repositoryName: "Repo", subject: "Yesterday collect", committedAt: startOfDay(-2))]
        )
        let service = BriefGenerationService(store: store, collector: collector)
        let yesterday = startOfDay(-1)
        let today = startOfDay(0)
        try store.save(BriefComposer.compose(
            day: yesterday,
            activities: [activity("Yesterday stored", on: startOfDay(-2))]
        ))
        try store.save(BriefComposer.compose(
            day: today,
            activities: [activity("Today already stored", on: yesterday)]
        ))

        let yesterdayToken = service.beginOperation(.generate, for: yesterday)
        let yesterdayTask = Task {
            await service.regenerate(for: yesterday, workspacePaths: ["/tmp/Repo"], token: yesterdayToken)
        }
        await waitUntil { collector.pendingCount == 1 }

        let todayToken = service.beginOperation(.generate, for: today)
        let todayOutcome = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"], token: todayToken)
        guard case .applied(let todayBrief) = todayOutcome else {
            return XCTFail("Expected today's stored brief")
        }
        XCTAssertEqual(todayBrief.day, today)

        collector.releaseOldest()
        let yesterdayOutcome = await yesterdayTask.value
        XCTAssertEqual(yesterdayOutcome, .superseded)

        let reloadedToday = try XCTUnwrap(store.load(forDay: today))
        XCTAssertTrue(reloadedToday.yesterdayLines.contains(where: { $0.contains("Today already stored") }))
        XCTAssertFalse(reloadedToday.yesterdayLines.contains(where: { $0.contains("Yesterday collect") }))
    }

    func testQuietAutoGenerationKeepsAlreadyRecordedReport() async throws {
        // First generation records the last active day; a later all-quiet
        // lookback must not erase it.
        let service = BriefGenerationService(store: store, collector: LookbackCollector(days: [
            startOfDay(-1): [activity("Real work", on: startOfDay(-1))]
        ]))
        let today = startOfDay(0)

        let first = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        XCTAssertTrue(first.yesterdayLines.contains(where: { $0.contains("Real work") }))

        let quietService = BriefGenerationService(store: store, collector: LookbackCollector(days: [:]))
        let regenerated = await quietService.regenerate(for: today, workspacePaths: ["/tmp/Repo"])
        XCTAssertTrue(
            regenerated.yesterdayLines.contains(where: { $0.contains("Real work") }),
            "quiet lookback keeps the recorded report"
        )

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertTrue(reloaded.yesterdayLines.contains(where: { $0.contains("Real work") }))
    }

    func testAttributionStorePersistsAliasesAndDoesNotOverwriteConfirmedIdentity() throws {
        let suite = "brief-attr-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = BriefAttributionStore(defaults: defaults)
        let workspaceID = UUID()
        store.recordDefault(
            BriefAuthorIdentity(name: "Alice", emails: ["alice@example.test"]),
            for: workspaceID
        )
        XCTAssertFalse(store.selection(for: workspaceID)?.confirmed ?? true)

        store.setIdentity(
            BriefAuthorIdentity(name: "Alice", emails: ["alice@example.test", "alice.work@example.test"]),
            for: workspaceID,
            confirmed: true
        )
        XCTAssertEqual(
            store.selection(for: workspaceID)?.identity.emails,
            ["alice@example.test", "alice.work@example.test"]
        )

        store.recordDefault(
            BriefAuthorIdentity(name: "Other", emails: ["other@example.test"]),
            for: workspaceID
        )
        XCTAssertEqual(store.selection(for: workspaceID)?.identity.emails.last, "alice.work@example.test")

        let reloaded = BriefAttributionStore(defaults: defaults)
        XCTAssertEqual(reloaded.selection(for: workspaceID)?.identity.emails.count, 2)
        defaults.removePersistentDomain(forName: suite)
    }

    private func dateInNewYork(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.date(from: string)!
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Condition not met before timeout", file: file, line: line)
    }
}

// MARK: - Fixtures

/// Deterministic stand-in for git collection; synthetic data only.
struct StubCollector: BriefActivityCollecting {
    let activityCount: Int

    func collectActivities(_ request: BriefCollectionRequest) async -> BriefCollectionResult {
        guard !request.sources.isEmpty else { return .empty }
        let activities = (0..<activityCount).map { index in
            CommitActivity(
                repositoryName: "Repo\(index)",
                subject: "Commit \(index)",
                committedAt: request.rangeStart
            )
        }
        let repositories = request.sources.map {
            BriefSourceRepository(displayName: $0.displayName, identity: $0.path)
        }
        return BriefCollectionResult(activities: activities, sourceRepositories: repositories)
    }
}

/// Returns per-day commit groups within the requested lookback window, so
/// previous-workday auto-detection can be exercised without git.
struct LookbackCollector: BriefActivityCollecting {
    let days: [Date: [CommitActivity]]

    func collectActivities(_ request: BriefCollectionRequest) async -> BriefCollectionResult {
        let calendar = request.calendar
        let inWindow = days.filter { day, _ in
            day >= calendar.startOfDay(for: request.rangeStart) && day < request.rangeEnd
        }
        let activities = inWindow.values.flatMap { $0 }
        let repositories = request.sources.map {
            BriefSourceRepository(displayName: $0.displayName, identity: $0.path)
        }
        return BriefCollectionResult(activities: activities, sourceRepositories: repositories)
    }
}

/// Records the last collection request so tests can assert date-range wiring.
final class RecordingCollector: BriefActivityCollecting, @unchecked Sendable {
    private let inner: StubCollector
    private let lock = NSLock()
    private var _lastRequest: BriefCollectionRequest?

    var lastRequest: BriefCollectionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    init(activityCount: Int) {
        inner = StubCollector(activityCount: activityCount)
    }

    func collectActivities(_ request: BriefCollectionRequest) async -> BriefCollectionResult {
        lock.lock()
        _lastRequest = request
        lock.unlock()
        return await inner.collectActivities(request)
    }
}

/// Suspends each `collectActivities` call until `releaseOldest()` so tests can
/// interleave operations while generation is in flight.
final class SuspendableActivityCollector: BriefActivityCollecting, @unchecked Sendable {
    var activities: [CommitActivity]
    private let gate = BriefContinuationGate()

    var pendingCount: Int { gate.pendingCount }

    init(activities: [CommitActivity]) {
        self.activities = activities
    }

    func collectActivities(_ request: BriefCollectionRequest) async -> BriefCollectionResult {
        await gate.wait()
        let repositories = request.sources.map {
            BriefSourceRepository(displayName: $0.displayName, identity: $0.path)
        }
        return BriefCollectionResult(activities: activities, sourceRepositories: repositories)
    }

    func releaseOldest() {
        gate.releaseOldest()
    }
}

final class BriefContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func wait() async {
        if Task.isCancelled { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                pending.append(continuation)
                lock.unlock()
            }
        } onCancel: { [self] in
            releaseOldest()
        }
    }

    func releaseOldest() {
        lock.lock()
        let continuation = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        continuation?.resume()
    }
}
