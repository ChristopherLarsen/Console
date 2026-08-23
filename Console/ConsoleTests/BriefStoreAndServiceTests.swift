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

        let parsed = BriefAIResponseParser.Parsed(
            yesterdayLines: ["Polished line"],
            todayTasks: ["AI task"]
        )
        let refined = service.applyRefinement(parsed, to: brief)
        XCTAssertEqual(refined.yesterdayLines, ["Polished line"])
        XCTAssertEqual(refined.todayTasks, ["AI task"])
        XCTAssertEqual(refined.source, .ai)

        brief.tasksManuallyEdited = true
        let refinedAgain = service.applyRefinement(parsed, to: brief)
        XCTAssertEqual(refinedAgain.todayTasks, brief.todayTasks)
        XCTAssertEqual(refinedAgain.yesterdayLines, ["Polished line"])
    }
}

// MARK: - Fixtures

/// Deterministic stand-in for git collection; synthetic data only.
private struct StubCollector: BriefActivityCollecting {
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
