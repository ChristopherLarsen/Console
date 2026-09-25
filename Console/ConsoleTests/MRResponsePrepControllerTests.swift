import XCTest
@testable import Console

@MainActor
final class MRResponsePrepControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var fetches: [URL] = []
    private var fetchResult: Result<Int, Error> = .success(2)
    private var launches: [URL] = []
    private var submissions: [(UUID, String)] = []
    private var onSubmitted: [@MainActor () -> Void] = []
    private var sessions: [MRResponsePrepController.SessionStatus] = []
    private var keptEvidence: [Set<URL>] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "MRResponsePrepControllerTests-\(UUID().uuidString)")
        fetches = []
        fetchResult = .success(2)
        launches = []
        submissions = []
        onSubmitted = []
        sessions = []
        keptEvidence = []
    }

    // MARK: - Fixtures

    private func item(_ iid: Int, count: Int) -> AuthoredMRAttention {
        let data = """
        {"project":"group/app","iid":\(iid),"url":"https://gitlab.example.test/group/app/-/merge_requests/\(iid)",
         "title":"Change \(iid)","authorUsername":"me","state":"opened","unresolvedDiscussionCount":\(count),
         "externalApprovalCount":0,"approvalRulesSatisfied":false,"jiraIssueKey":null}
        """
        return try! JSONDecoder().decode(AuthoredMRAttention.self, from: Data(data.utf8))
    }

    private func makeController() -> MRResponsePrepController {
        let controller = MRResponsePrepController(
            defaults: defaults,
            fetcher: { [unowned self] item, _ in
                fetches.append(item.url)
                return try fetchResult.get()
            },
            launcher: { [unowned self] item, directory, _, submitted in
                launches.append(item.url)
                onSubmitted.append(submitted)
                let session = MRResponsePrepController.SessionStatus(id: UUID(), claudeSessionID: UUID(), activity: .starting)
                sessions.append(session)
                return .init(sessionID: session.id, claudeSessionID: session.claudeSessionID,
                             name: "MR-\(item.iid) Response", workingDirectory: directory)
            },
            submitter: { [unowned self] id, prompt in
                submissions.append((id, prompt))
            },
            directoryProvider: { URL(fileURLWithPath: "/tmp/prep-\($0.iid)") },
            promptProvider: { item, _ in "prep \(item.iid)" },
            evidenceCleaner: { [unowned self] kept in keptEvidence.append(kept) }
        )
        controller.sessionsProvider = { [unowned self] in sessions }
        return controller
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func setActivity(_ activity: SessionActivity, forSessionAt index: Int) {
        let old = sessions[index]
        sessions[index] = .init(id: old.id, claudeSessionID: old.claudeSessionID, activity: activity)
    }

    // MARK: - Triggering

    func testScanPreparesMergeRequestsWithUnresolvedCommentsOnly() async {
        let controller = makeController()
        controller.handleAuthoredScan([item(1, count: 2), item(2, count: 0)])
        await settle()

        XCTAssertEqual(controller.items.map(\.iid), [1])
        XCTAssertEqual(launches, [item(1, count: 2).url])
        XCTAssertEqual(controller.state(for: item(1, count: 2)), .preparing)
    }

    func testSameCountIsNotPreparedTwiceButANewCommentIs() async {
        let controller = makeController()
        controller.handleAuthoredScan([item(1, count: 2)])
        await settle()
        onSubmitted[0]()
        controller.handleLifecycle(sessionID: sessions[0].id, event: .turnCompleted)
        setActivity(.idle, forSessionAt: 0)

        controller.handleAuthoredScan([item(1, count: 2)])
        await settle()
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(submissions.isEmpty)

        controller.handleAuthoredScan([item(1, count: 3)])
        await settle()
        XCTAssertEqual(launches.count, 1, "an idle live prep session is reused")
        XCTAssertEqual(submissions.map(\.0), [sessions[0].id])
        XCTAssertEqual(controller.state(for: item(1, count: 3)), .preparing)
    }

    func testResolvedThreadsLowerTheBaselineSoALaterCommentRetriggers() async {
        let controller = makeController()
        controller.handleAuthoredScan([item(1, count: 3)])
        await settle()
        onSubmitted[0]()
        controller.handleLifecycle(sessionID: sessions[0].id, event: .turnCompleted)
        setActivity(.exited, forSessionAt: 0)

        controller.handleAuthoredScan([item(1, count: 1)])
        await settle()
        XCTAssertEqual(launches.count, 1)

        controller.handleAuthoredScan([item(1, count: 2)])
        await settle()
        XCTAssertEqual(launches.count, 2, "an exited prep session is replaced by a new one")
    }

    func testDisabledSettingWaitsForAnExplicitPrepare() async {
        defaults.set(false, forKey: AppSettings.mrResponsePrepEnabledKey)
        let controller = makeController()
        controller.handleAuthoredScan([item(1, count: 2)])
        await settle()
        XCTAssertTrue(launches.isEmpty)
        XCTAssertEqual(controller.state(for: item(1, count: 2)), .notPrepared)

        await controller.prepare(item(1, count: 2))?.value
        XCTAssertEqual(launches.count, 1)
    }

    func testNoMoreThanTwoPrepsRunAtOnce() async {
        let controller = makeController()
        controller.handleAuthoredScan([item(1, count: 1), item(2, count: 1), item(3, count: 1)])
        await settle()
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(controller.state(for: item(3, count: 1)), .notPrepared)

        onSubmitted[0]()
        controller.handleLifecycle(sessionID: sessions[0].id, event: .turnCompleted)
        await settle()
        XCTAssertEqual(launches.count, 3, "a finished prep frees a slot for the next merge request")
    }

    // MARK: - Card state

    func testCardStateFollowsPromptThenTurnCompletion() async {
        let controller = makeController()
        let mr = item(1, count: 2)
        controller.handleAuthoredScan([mr])
        await settle()
        let id = sessions[0].id

        controller.handleLifecycle(sessionID: id, event: .turnCompleted)
        XCTAssertEqual(controller.state(for: mr), .preparing, "a turn before the prep prompt is not the prep")

        onSubmitted[0]()
        XCTAssertEqual(controller.state(for: mr), .preparing)
        controller.handleLifecycle(sessionID: id, event: .turnCompleted)
        XCTAssertEqual(controller.state(for: mr), .ready)
        XCTAssertEqual(controller.liveSessionID(for: mr), id)
    }

    func testEndingBeforeTheDraftsFinishIsInterruptedAndResumable() async throws {
        let controller = makeController()
        let mr = item(1, count: 2)
        controller.handleAuthoredScan([mr])
        await settle()
        onSubmitted[0]()
        setActivity(.exited, forSessionAt: 0)
        controller.handleLifecycle(sessionID: sessions[0].id, event: .processTerminated)

        XCTAssertEqual(controller.state(for: mr), .interrupted)
        XCTAssertNil(controller.liveSessionID(for: mr))
        let record = try XCTUnwrap(controller.resumableRecord(for: mr))
        XCTAssertEqual(record.claudeSessionID, sessions[0].claudeSessionID)
        XCTAssertEqual(record.purpose, .general)
    }

    func testFetchFailureIsShownAndNotRetriedAutomatically() async {
        fetchResult = .failure(MRResponsePrepFetcher.FetchError.requestFailed("discussions"))
        let controller = makeController()
        let mr = item(1, count: 2)
        controller.handleAuthoredScan([mr])
        await settle()

        XCTAssertTrue(launches.isEmpty)
        guard case .failed = controller.state(for: mr) else { return XCTFail("expected failure") }

        controller.handleAuthoredScan([mr])
        await settle()
        XCTAssertEqual(fetches.count, 1)

        fetchResult = .success(2)
        await controller.prepare(mr)?.value
        XCTAssertEqual(launches.count, 1, "Retry prepares again")
    }

    func testStateSurvivesRelaunchAndMergedRequestsArePruned() async {
        let controller = makeController()
        let mr = item(1, count: 2)
        controller.handleAuthoredScan([mr])
        await settle()
        onSubmitted[0]()
        controller.handleLifecycle(sessionID: sessions[0].id, event: .turnCompleted)

        let relaunched = makeController()
        relaunched.handleAuthoredScan([mr])
        await settle()
        XCTAssertEqual(relaunched.state(for: mr), .ready)
        XCTAssertEqual(launches.count, 1)

        relaunched.handleAuthoredScan([])
        XCTAssertTrue(relaunched.entries.isEmpty)
        XCTAssertTrue(relaunched.items.isEmpty)
        XCTAssertEqual(keptEvidence.last, [], "evidence for pruned merge requests is deleted")
    }

    func testRefreshWaitsWhileTheUserHasThePrepSessionSelected() async {
        let controller = makeController()
        controller.handleAuthoredScan([item(1, count: 1)])
        await settle()
        onSubmitted[0]()
        controller.handleLifecycle(sessionID: sessions[0].id, event: .turnCompleted)
        sessions[0] = .init(id: sessions[0].id, claudeSessionID: sessions[0].claudeSessionID,
                            activity: .idle, isSelected: true)

        controller.handleAuthoredScan([item(1, count: 2)])
        await settle()
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(controller.needsPrep(item(1, count: 2)), "the next scan retries")
    }
}
