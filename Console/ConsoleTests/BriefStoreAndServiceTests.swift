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

        store.save(brief)
        let loaded = try XCTUnwrap(store.load(forDay: day))

        XCTAssertEqual(loaded.day, brief.day)
        XCTAssertEqual(loaded.yesterdayLines, brief.yesterdayLines)
        XCTAssertEqual(loaded.todayTasks, brief.todayTasks)
        XCTAssertTrue(loaded.tasksManuallyEdited)
        XCTAssertEqual(loaded.source, .ai)
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

    func collectActivities(workspacePaths: [String], day: Date, calendar: Calendar) async -> [CommitActivity] {
        guard !workspacePaths.isEmpty else { return [] }
        return (0..<activityCount).map { index in
            CommitActivity(
                repositoryName: "Repo\(index)",
                subject: "Commit \(index)",
                committedAt: calendar.startOfDay(for: day)
            )
        }
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

    func collectActivities(workspacePaths: [String], day: Date, calendar: Calendar) async -> [CommitActivity] {
        await gate.wait()
        return activities
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
