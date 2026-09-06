import XCTest
@testable import Console

@MainActor
final class BriefViewModelTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: BriefStore!
    private let calendar = Calendar.current

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-viewmodel-tests-\(UUID().uuidString)", isDirectory: true)
        store = BriefStore(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        store = nil
        tempDirectory = nil
        super.tearDown()
    }

    private func startOfDay(_ offset: Int, from reference: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference))!
    }

    private func activity(_ subject: String, on day: Date) -> CommitActivity {
        CommitActivity(repositoryName: "Repo", subject: subject, committedAt: day)
    }

    private func seedBrief(day: Date, subject: String, tasks: [String]) {
        store.save(BriefComposer.compose(
            day: day,
            activities: [activity(subject, on: calendar.date(byAdding: .day, value: -1, to: day)!)],
            carriedTasks: tasks
        ))
    }

    private func makeViewModel(
        collector: SuspendableActivityCollector,
        refiner: SuspendableBriefRefiner
    ) -> BriefViewModel {
        let service = BriefGenerationService(store: store, collector: collector)
        return BriefViewModel(
            generationService: service,
            workspacePathsProvider: { ["/tmp/Repo"] },
            refiner: refiner
        )
    }

    // MARK: - Edits during generation

    func testTaskEditsSurviveSuspendedRegenerationInUIAndAfterReload() async throws {
        let today = startOfDay(0)
        seedBrief(day: today, subject: "Old work", tasks: ["Original"])
        let collector = SuspendableActivityCollector(activities: [activity("New work", on: startOfDay(-1))])
        let refiner = SuspendableBriefRefiner(parsed: .init(yesterdayLines: ["AI line"], todayTasks: ["AI task"]))
        let viewModel = makeViewModel(collector: collector, refiner: refiner)

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { viewModel.brief != nil }

        viewModel.regenerate()
        await waitUntil { collector.pendingCount == 1 }

        viewModel.updateTask(at: 0, text: "Edited")
        viewModel.addTask()
        viewModel.updateTask(at: 1, text: "Added")
        viewModel.removeTask(at: 0)

        collector.releaseOldest()
        await waitUntil { !viewModel.isLoading }

        XCTAssertEqual(viewModel.brief?.todayTasks, ["Added"])
        XCTAssertTrue(viewModel.brief?.tasksManuallyEdited ?? false)
        XCTAssertTrue(viewModel.brief?.yesterdayLines.contains(where: { $0.contains("New work") }) ?? false)

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloaded.todayTasks, ["Added"])
        XCTAssertTrue(reloaded.tasksManuallyEdited)
        XCTAssertTrue(reloaded.yesterdayLines.contains(where: { $0.contains("New work") }))
    }

    // MARK: - Edits during refinement

    func testTaskEditsSurviveSuspendedRefinementInUIAndAfterReload() async throws {
        let today = startOfDay(0)
        seedBrief(day: today, subject: "Local work", tasks: ["Original"])
        let collector = SuspendableActivityCollector(activities: [activity("Unused", on: startOfDay(-1))])
        let refiner = SuspendableBriefRefiner(
            parsed: .init(yesterdayLines: ["Polished work"], todayTasks: ["AI should not win"])
        )
        let viewModel = makeViewModel(collector: collector, refiner: refiner)

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { viewModel.brief != nil }

        viewModel.refineWithAI(aiProviderManager: nil)
        await waitUntil { refiner.pendingCount == 1 }

        viewModel.updateTask(at: 0, text: "Edited")
        viewModel.addTask()
        viewModel.updateTask(at: 1, text: "Added")
        viewModel.removeTask(at: 1)

        refiner.releaseOldest()
        await waitUntil { !viewModel.isRefining }

        XCTAssertEqual(viewModel.brief?.todayTasks, ["Edited"])
        XCTAssertTrue(viewModel.brief?.tasksManuallyEdited ?? false)
        XCTAssertEqual(viewModel.brief?.yesterdayLines, ["Polished work"])
        XCTAssertEqual(viewModel.brief?.source, .ai)

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloaded.todayTasks, ["Edited"])
        XCTAssertEqual(reloaded.yesterdayLines, ["Polished work"])
    }

    // MARK: - Overlapping regenerate / refine

    func testOverlappingCompletionsPreferLastStarted_refineThenRegenerateReleasedEitherOrder() async throws {
        try await assertLastStartedWins(
            startRefineFirst: true,
            releaseFirstStartedFirst: true
        )
        try resetStore()
        try await assertLastStartedWins(
            startRefineFirst: true,
            releaseFirstStartedFirst: false
        )
    }

    func testOverlappingCompletionsPreferLastStarted_regenerateThenRefineReleasedEitherOrder() async throws {
        try await assertLastStartedWins(
            startRefineFirst: false,
            releaseFirstStartedFirst: true
        )
        try resetStore()
        try await assertLastStartedWins(
            startRefineFirst: false,
            releaseFirstStartedFirst: false
        )
    }

    // MARK: - Previous day cannot replace today

    func testPreviousDayDelayedGenerationDoesNotReplaceTodaysDisplayedBrief() async throws {
        let yesterday = startOfDay(-1)
        let today = startOfDay(0)
        seedBrief(day: today, subject: "Today already stored", tasks: ["Today plan"])

        let collector = SuspendableActivityCollector(
            activities: [activity("Yesterday collect", on: startOfDay(-2))]
        )
        let refiner = SuspendableBriefRefiner(parsed: .init(yesterdayLines: ["AI"], todayTasks: ["AI"]))
        let viewModel = makeViewModel(collector: collector, refiner: refiner)

        viewModel.prepareIfNeeded(now: yesterday)
        await waitUntil { collector.pendingCount == 1 }

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { viewModel.brief?.day == today }
        XCTAssertEqual(viewModel.brief?.todayTasks, ["Today plan"])

        collector.releaseOldest()
        await waitUntil { !viewModel.isLoading }

        XCTAssertEqual(viewModel.brief?.day, today)
        XCTAssertEqual(viewModel.brief?.todayTasks, ["Today plan"])
        XCTAssertTrue(viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Today already stored") }) ?? false)
        XCTAssertFalse(viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Yesterday collect") }) ?? false)

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloaded.todayTasks, ["Today plan"])
        XCTAssertFalse(reloaded.yesterdayLines.contains(where: { $0.contains("Yesterday collect") }))
    }

    // MARK: - Helpers

    private func assertLastStartedWins(startRefineFirst: Bool,
                                       releaseFirstStartedFirst: Bool) async throws {
        let today = startOfDay(0)
        seedBrief(day: today, subject: "Seed work", tasks: ["Original"])
        let collector = SuspendableActivityCollector(
            activities: [activity("Generated work", on: startOfDay(-1))]
        )
        let refiner = SuspendableBriefRefiner(
            parsed: .init(yesterdayLines: ["Refined work"], todayTasks: ["AI task"])
        )
        let viewModel = makeViewModel(collector: collector, refiner: refiner)
        viewModel.prepareIfNeeded(now: today)
        await waitUntil { viewModel.brief != nil }

        if startRefineFirst {
            viewModel.refineWithAI(aiProviderManager: nil)
            await waitUntil { refiner.pendingCount == 1 }
            viewModel.regenerate()
            await waitUntil { viewModel.isLoading && !viewModel.isRefining }
            await waitUntil { collector.pendingCount == 1 }
        } else {
            viewModel.regenerate()
            await waitUntil { collector.pendingCount == 1 }
            viewModel.refineWithAI(aiProviderManager: nil)
            await waitUntil { viewModel.isRefining && !viewModel.isLoading }
            await waitUntil { refiner.pendingCount == 1 }
        }

        viewModel.updateTask(at: 0, text: "Kept through overlap")

        let firstIsRefine = startRefineFirst
        if releaseFirstStartedFirst {
            if firstIsRefine {
                refiner.releaseOldest()
                collector.releaseOldest()
            } else {
                collector.releaseOldest()
                refiner.releaseOldest()
            }
        } else {
            if firstIsRefine {
                collector.releaseOldest()
                refiner.releaseOldest()
            } else {
                refiner.releaseOldest()
                collector.releaseOldest()
            }
        }

        await waitUntil { !viewModel.isLoading && !viewModel.isRefining }

        XCTAssertEqual(viewModel.brief?.todayTasks, ["Kept through overlap"])
        XCTAssertTrue(viewModel.brief?.tasksManuallyEdited ?? false)

        let lastStartedIsRegenerate = startRefineFirst
        if lastStartedIsRegenerate {
            XCTAssertTrue(viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Generated work") }) ?? false)
            XCTAssertNotEqual(viewModel.brief?.yesterdayLines, ["Refined work"])
            XCTAssertEqual(viewModel.brief?.source, .local)
        } else {
            XCTAssertEqual(viewModel.brief?.yesterdayLines, ["Refined work"])
            XCTAssertEqual(viewModel.brief?.source, .ai)
        }

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertEqual(reloaded.todayTasks, ["Kept through overlap"])
        if lastStartedIsRegenerate {
            XCTAssertTrue(reloaded.yesterdayLines.contains(where: { $0.contains("Generated work") }))
        } else {
            XCTAssertEqual(reloaded.yesterdayLines, ["Refined work"])
        }
    }

    private func resetStore() throws {
        try FileManager.default.removeItem(at: tempDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = BriefStore(directory: tempDirectory)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
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

@MainActor
final class SuspendableBriefRefiner: BriefRefining {
    var parsed: BriefAIResponseParser.Parsed
    private let gate = BriefContinuationGate()

    var pendingCount: Int { gate.pendingCount }

    init(parsed: BriefAIResponseParser.Parsed) {
        self.parsed = parsed
    }

    func refine(yesterdayLines: [String], todayTasks: [String]) async throws -> BriefAIResponseParser.Parsed {
        await gate.wait()
        if Task.isCancelled { throw CancellationError() }
        return parsed
    }

    func releaseOldest() {
        gate.releaseOldest()
    }
}
