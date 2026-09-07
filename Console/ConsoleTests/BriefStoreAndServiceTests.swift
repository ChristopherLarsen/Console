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

    // MARK: - Persistence round trip

    func testSaveAndLoadRoundTripsBrief() throws {
        let day = startOfDay(0)
        var brief = BriefComposer.compose(
            day: day,
            activities: [CommitActivity(repositoryName: "Alpha", subject: "Did work", committedAt: day)],
            carriedTasks: ["Task"]
        )
        brief.tasksManuallyEdited = true
        brief.source = .ai
        brief.activityRangeStart = day
        brief.activityRangeEnd = calendar.date(byAdding: .day, value: 1, to: day)
        brief.sourceRepositoryNames = ["Alpha"]

        store.save(brief)
        let loaded = try XCTUnwrap(store.load(forDay: day))

        XCTAssertEqual(loaded.day, brief.day)
        XCTAssertEqual(loaded.yesterdayLines, brief.yesterdayLines)
        XCTAssertEqual(loaded.todayTasks, brief.todayTasks)
        XCTAssertTrue(loaded.tasksManuallyEdited)
        XCTAssertEqual(loaded.source, .ai)
        XCTAssertEqual(loaded.activityRangeStart, brief.activityRangeStart)
        XCTAssertEqual(loaded.activityRangeEnd, brief.activityRangeEnd)
        XCTAssertEqual(loaded.sourceRepositoryNames, ["Alpha"])
    }

    func testLoadMissingDayReturnsNil() {
        XCTAssertNil(store.load(forDay: startOfDay(-5)))
    }

    // MARK: - Carry-forward queries

    func testLoadMostRecentReturnsLatestEarlierBriefOnly() throws {
        let today = startOfDay(0)
        let yesterday = startOfDay(-1)
        let older = startOfDay(-3)

        store.save(BriefComposer.compose(day: older, activities: [], carriedTasks: ["Old plan"]))
        store.save(BriefComposer.compose(day: yesterday, activities: [], carriedTasks: ["Recent plan"]))

        let carried = try XCTUnwrap(store.loadMostRecent(before: today))
        XCTAssertEqual(carried.day, yesterday)
        XCTAssertEqual(carried.todayTasks, ["Recent plan"])
    }

    func testLoadMostRecentWithNoHistoryReturnsNil() {
        XCTAssertNil(store.loadMostRecent(before: startOfDay(0)))
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

    func testRegeneratePreservesManuallyEditedTasks() async throws {
        let service = BriefGenerationService(store: store, collector: StubCollector(activityCount: 1))
        let today = startOfDay(0)

        let first = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        let edited = service.updateTasks(["My own task"], in: first)
        XCTAssertTrue(edited.tasksManuallyEdited)

        let regenerated = await service.regenerate(for: today, workspacePaths: ["/tmp/Repo"])
        XCTAssertEqual(regenerated.todayTasks, ["My own task"])
        XCTAssertTrue(regenerated.tasksManuallyEdited)
        XCTAssertEqual(regenerated.source, .local)
    }

    func testApplyRefinementTakesAITasksOnlyWhenNotManuallyEdited() async {
        let service = BriefGenerationService(store: store, collector: StubCollector(activityCount: 1))
        let today = startOfDay(0)

        var brief = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        brief.tasksManuallyEdited = false
        store.save(brief)

        let parsed = BriefAIResponseParser.Parsed(
            yesterdayLines: ["Polished line"],
            todayTasks: ["AI task"]
        )
        let refined = service.applyRefinement(parsed, to: brief)
        XCTAssertEqual(refined.yesterdayLines, ["Polished line"])
        XCTAssertEqual(refined.todayTasks, ["AI task"])
        XCTAssertEqual(refined.source, .ai)

        let edited = service.updateTasks(["Hand edited"], in: refined)
        let refinedAgain = service.applyRefinement(parsed, to: edited)
        XCTAssertEqual(refinedAgain.todayTasks, ["Hand edited"])
        XCTAssertEqual(refinedAgain.yesterdayLines, ["Polished line"])
    }

    func testApplyRefinementTokenPreservesEditsMadeAfterBegin() async throws {
        let service = BriefGenerationService(store: store, collector: StubCollector(activityCount: 1))
        let today = startOfDay(0)
        let brief = await service.ensureBrief(for: today, workspacePaths: ["/tmp/Repo"])
        let token = service.beginOperation(.refine, for: today)
        _ = service.updateTasks(["Typed while refining"], in: brief)

        let parsed = BriefAIResponseParser.Parsed(
            yesterdayLines: ["Polished while editing"],
            todayTasks: ["AI should lose"]
        )
        let outcome = service.applyRefinement(parsed, token: token)
        guard case .applied(let refined) = outcome else {
            return XCTFail("Expected current refinement to apply")
        }
        XCTAssertEqual(refined.yesterdayLines, ["Polished while editing"])
        XCTAssertEqual(refined.todayTasks, ["Typed while refining"])
        XCTAssertTrue(refined.tasksManuallyEdited)

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloaded.todayTasks, ["Typed while refining"])
    }

    func testRegeneratePreservesEditsMadeWhileCollectionIsSuspended() async throws {
        let collector = SuspendableActivityCollector(
            activities: [CommitActivity(repositoryName: "Repo", subject: "New work", committedAt: startOfDay(-1))]
        )
        let service = BriefGenerationService(store: store, collector: collector)
        let today = startOfDay(0)
        var seed = BriefComposer.compose(
            day: today,
            activities: [CommitActivity(repositoryName: "Repo", subject: "Old work", committedAt: startOfDay(-1))],
            carriedTasks: ["Original task"]
        )
        seed.tasksManuallyEdited = false
        store.save(seed)

        let token = service.beginOperation(.generate, for: today)
        let generateTask = Task {
            await service.regenerate(for: today, workspacePaths: ["/tmp/Repo"], token: token)
        }
        await waitUntil { collector.pendingCount == 1 }

        let during = try XCTUnwrap(store.load(forDay: today))
        _ = service.updateTasks(["Edited during generate"], in: during)

        collector.releaseOldest()
        let outcome = await generateTask.value

        guard case .applied(let regenerated) = outcome else {
            return XCTFail("Expected generation to apply")
        }
        XCTAssertEqual(regenerated.todayTasks, ["Edited during generate"])
        XCTAssertTrue(regenerated.tasksManuallyEdited)
        XCTAssertTrue(regenerated.yesterdayLines.contains(where: { $0.contains("New work") }))

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloaded.todayTasks, ["Edited during generate"])
        XCTAssertTrue(reloaded.yesterdayLines.contains(where: { $0.contains("New work") }))
    }

    func testSupersededGenerationDoesNotWriteDisk() async throws {
        let collector = SuspendableActivityCollector(
            activities: [CommitActivity(repositoryName: "Repo", subject: "First collect", committedAt: startOfDay(-1))]
        )
        let service = BriefGenerationService(store: store, collector: collector)
        let today = startOfDay(0)
        store.save(BriefComposer.compose(day: today, activities: [], carriedTasks: ["Keep me"]))

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
        XCTAssertEqual(afterFirst.todayTasks, ["Keep me"])
        XCTAssertFalse(afterFirst.yesterdayLines.contains(where: { $0.contains("First collect") }))

        collector.releaseOldest()
        let secondOutcome = await second.value
        guard case .applied(let regenerated) = secondOutcome else {
            return XCTFail("Expected the current generation to apply")
        }
        XCTAssertEqual(regenerated.todayTasks, ["Keep me"])
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
        store.save(BriefComposer.compose(day: yesterday, activities: [], carriedTasks: ["Yesterday plan"]))
        store.save(BriefComposer.compose(
            day: today,
            activities: [CommitActivity(repositoryName: "Repo", subject: "Today already stored", committedAt: yesterday)],
            carriedTasks: ["Today plan"]
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
        XCTAssertEqual(todayBrief.todayTasks, ["Today plan"])

        collector.releaseOldest()
        let yesterdayOutcome = await yesterdayTask.value
        XCTAssertEqual(yesterdayOutcome, .superseded)

        let reloadedToday = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloadedToday.todayTasks, ["Today plan"])
        XCTAssertTrue(reloadedToday.yesterdayLines.contains(where: { $0.contains("Today already stored") }))
        XCTAssertFalse(reloadedToday.yesterdayLines.contains(where: { $0.contains("Yesterday collect") }))
    }

    func testRegenerateUsesCustomDateRangeAndRecordsSources() async throws {
        let collector = RecordingCollector(activityCount: 1)
        let service = BriefGenerationService(store: store, collector: collector)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let monday = calendar.startOfDay(for: dateInNewYork("2026-09-07T09:00:00"))
        let friday = calendar.startOfDay(for: dateInNewYork("2026-09-04T09:00:00"))
        let sunday = calendar.startOfDay(for: dateInNewYork("2026-09-06T09:00:00"))
        let range = BriefDateRangeSelection(preset: .custom, customStart: friday, customEnd: sunday)
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
            range: range
        )

        let request = try XCTUnwrap(collector.lastRequest)
        XCTAssertEqual(request.rangeStart, friday)
        XCTAssertEqual(request.rangeEnd, monday)
        XCTAssertEqual(brief.sourceRepositoryNames, ["Console"])
        XCTAssertEqual(brief.activityRangeStart, friday)
        XCTAssertEqual(brief.activityRangeEnd, monday)
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

        store.addEmail("alice.work@example.test", for: workspaceID)
        XCTAssertEqual(
            store.selection(for: workspaceID)?.identity.emails,
            ["alice@example.test", "alice.work@example.test"]
        )
        XCTAssertTrue(store.selection(for: workspaceID)?.confirmed ?? false)

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
/// edit tasks while generation is in flight.
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
