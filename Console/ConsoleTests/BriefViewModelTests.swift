import XCTest
@testable import Console

@MainActor
final class BriefViewModelTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: BriefStore!
    private var attributionDefaults: UserDefaults!
    private var attributionSuite: String!
    private let calendar = Calendar.current

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-viewmodel-tests-\(UUID().uuidString)", isDirectory: true)
        store = BriefStore(directory: tempDirectory)
        attributionSuite = "brief-viewmodel-attr-\(UUID().uuidString)"
        attributionDefaults = UserDefaults(suiteName: attributionSuite)!
        attributionDefaults.removePersistentDomain(forName: attributionSuite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        if let attributionSuite {
            attributionDefaults?.removePersistentDomain(forName: attributionSuite)
        }
        store = nil
        tempDirectory = nil
        attributionDefaults = nil
        attributionSuite = nil
        super.tearDown()
    }

    private func startOfDay(_ offset: Int, from reference: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference))!
    }

    private func activity(_ subject: String, on day: Date) -> CommitActivity {
        CommitActivity(repositoryName: "Repo", subject: subject, committedAt: day)
    }

    private func seedBrief(day: Date, subject: String) throws {
        try store.save(BriefComposer.compose(
            day: day,
            activities: [activity(subject, on: calendar.date(byAdding: .day, value: -1, to: day)!)]
        ))
    }

    private func makeViewModel(
        collector: SuspendableActivityCollector
    ) -> BriefViewModel {
        let service = BriefGenerationService(store: store, collector: collector)
        return BriefViewModel(
            generationService: service,
            workspacePathsProvider: { ["/tmp/Repo"] },
            attributionStore: BriefAttributionStore(defaults: attributionDefaults)
        )
    }

    // MARK: - Previous day cannot replace today

    func testPreviousDayDelayedGenerationDoesNotReplaceTodaysDisplayedBrief() async throws {
        let yesterday = startOfDay(-1)
        let today = startOfDay(0)
        try seedBrief(day: today, subject: "Today already stored")

        let collector = SuspendableActivityCollector(
            activities: [activity("Yesterday collect", on: startOfDay(-2))]
        )
        let viewModel = makeViewModel(collector: collector)

        viewModel.prepareIfNeeded(now: yesterday)
        await waitUntil { collector.pendingCount == 1 }

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { viewModel.brief?.day == today }

        collector.releaseOldest()
        await waitUntil { !viewModel.isLoading }

        XCTAssertEqual(viewModel.brief?.day, today)
        XCTAssertTrue(viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Today already stored") }) ?? false)
        XCTAssertFalse(viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Yesterday collect") }) ?? false)

        let reloaded = try XCTUnwrap(store.load(forDay: today))
        XCTAssertFalse(reloaded.yesterdayLines.contains(where: { $0.contains("Yesterday collect") }))
    }

    // MARK: - Workday choice

    func testChooseWorkdayRegeneratesForThePickedDay() async throws {
        let today = startOfDay(0)
        let picked = startOfDay(-6)
        let collector = SuspendableActivityCollector(
            activities: [
                activity("Recent work", on: startOfDay(-1)),
                activity("Picked day work", on: picked)
            ]
        )
        let viewModel = makeViewModel(collector: collector)

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { !viewModel.isLoading }
        XCTAssertTrue(
            viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Recent work") }) ?? false,
            "default brief reports the most recent active day"
        )

        viewModel.chooseWorkday(picked)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { !viewModel.isLoading }

        XCTAssertEqual(viewModel.brief?.activityRangeStart, picked)
        XCTAssertEqual(viewModel.brief?.yesterdayLines, ["Repo — Picked day work"])
        XCTAssertEqual(viewModel.selectedWorkday, picked)
    }

    func testDayRolloverClearsManualWorkdayPick() async throws {
        let today = startOfDay(0)
        let tomorrow = startOfDay(1)
        let picked = startOfDay(-6)
        let collector = SuspendableActivityCollector(
            activities: [activity("Fresh work", on: today)]
        )
        let viewModel = makeViewModel(collector: collector)

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { viewModel.brief?.day == today }

        viewModel.chooseWorkday(picked)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { !viewModel.isLoading }
        XCTAssertEqual(viewModel.selectedWorkday, picked)

        // Midnight passes while the panel stays selected (no onAppear):
        // the pick expires and auto-detection takes over again.
        viewModel.handleDayRollover(now: tomorrow)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { viewModel.brief?.day == tomorrow }

        XCTAssertNil(viewModel.selectedWorkday)
        XCTAssertTrue(
            viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Fresh work") }) ?? false
        )
    }

    // MARK: - Helpers

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

    // MARK: - H38-F04: day rollover without remounting

    func testDayRolloverRegeneratesNewDayWhilePanelStaysSelected() async throws {
        let today = startOfDay(0)
        let tomorrow = startOfDay(1)
        let collector = SuspendableActivityCollector(activities: [
            activity("Fresh work", on: today)
        ])
        let viewModel = makeViewModel(collector: collector)

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { viewModel.brief?.day == today }

        // Midnight passes while the panel stays selected (no onAppear).
        viewModel.handleDayRollover(now: tomorrow)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { viewModel.brief?.day == tomorrow }

        XCTAssertTrue(
            viewModel.brief?.yesterdayLines.contains(where: { $0.contains("Fresh work") }) ?? false
        )
    }

    func testDayRolloverOnSameDayIsNoOp() async throws {
        let today = startOfDay(0)
        try seedBrief(day: today, subject: "Stored work")
        let collector = SuspendableActivityCollector(activities: [])
        let viewModel = makeViewModel(collector: collector)

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { viewModel.brief != nil }

        viewModel.handleDayRollover(now: today.addingTimeInterval(3600))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.brief?.day, today, "same-day rollover must not regenerate")
        XCTAssertEqual(collector.pendingCount, 0)
    }

    // MARK: - H38-F03: save failures surface in the view model

    func testFailedSaveSurfacesErrorMessageForGeneration() async throws {
        let today = startOfDay(0)
        // Occupy the brief directory path with a file so every write fails.
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let blocked = tempDirectory.appendingPathComponent("blocked", isDirectory: true)
        try Data("occupant".utf8).write(to: blocked)
        let failingStore = BriefStore(directory: blocked)
        let collector = SuspendableActivityCollector(activities: [activity("Work", on: today)])
        let service = BriefGenerationService(
            store: failingStore,
            collector: collector
        )
        let viewModel = BriefViewModel(
            generationService: service,
            workspacePathsProvider: { ["/tmp/Repo"] },
            attributionStore: BriefAttributionStore(defaults: attributionDefaults)
        )

        viewModel.prepareIfNeeded(now: today)
        await waitUntil { collector.pendingCount == 1 }
        collector.releaseOldest()
        await waitUntil { viewModel.brief != nil }
        XCTAssertNotNil(
            viewModel.errorMessage,
            "generation whose save failed must not look like success"
        )
    }
}
