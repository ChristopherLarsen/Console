import XCTest
@testable import Console

/// Click journeys and launch gating for the Home work board model. All
/// navigation goes through the `actionExecutor` seam; snapshots are injected
/// so no WebView is ever touched.
@MainActor
final class HomeBoardModelTests: XCTestCase {

    private var actions: [HomeBoardModel.Action] = []
    private var launchedKeys: [String] = []
    private var refreshCount = 0

    private func makeTicket(
        key: String = "PROJ-1",
        status: String? = "To Do",
        order: Int = 0
    ) -> JiraTicketSummary {
        JiraTicketSummary(
            key: key,
            summary: "Story \(key)",
            status: status,
            priority: nil,
            updatedText: nil,
            issueURL: URL(string: "https://jira.example.test/browse/\(key)")!,
            sourceOrder: order
        )
    }

    private func makeReviewItem(iid: String = "1", order: Int = 0) -> MergeRequestSummary {
        MergeRequestSummary(
            id: URL(string: "https://gitlab.example.test/p/r/-/merge_requests/\(iid)")!,
            iidText: iid,
            title: "MR \(iid)",
            projectDisplayName: "Project",
            authorDisplayName: nil,
            isDraft: false,
            pipelineDisplayState: nil,
            reviewDisplayState: "Changes requested",
            updatedText: nil,
            mergeRequestURL: URL(string: "https://gitlab.example.test/p/r/-/merge_requests/\(iid)")!,
            sourceOrder: order
        )
    }

    private func makeModel(snapshot: HomeBoardSnapshot) -> HomeBoardModel {
        let model = HomeBoardModel(
            jiraController: JiraPanelController(),
            reviewsController: MRReviewScanController(urlProvider: { "" })
        )
        model.snapshotHandler = { snapshot }
        model.actionExecutor = { [weak self] action in self?.actions.append(action) }
        model.startSessionHandler = { [weak self] key, _, _ in
            self?.launchedKeys.append(key)
        }
        model.refreshJiraHandler = { [weak self] in self?.refreshCount += 1 }
        return model
    }

    // MARK: - Open story

    func testOpenStoryDeepLinksToJiraIssue() {
        let ticket = makeTicket()
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: .current
        ))
        model.openStory(ticket)
        XCTAssertEqual(actions, [.openJiraIssue(url: ticket.issueURL)])
    }

    func testOpenStoryVanishedFromCurrentDataStaysAndNotices() {
        let ticket = makeTicket()
        let model = makeModel(snapshot: HomeBoardSnapshot(jiraTickets: [], jiraStatus: .current))
        model.openStory(ticket)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(model.notice, HomeBoardModel.vanishedNotice)
    }

    func testOpenStoryFromRetainedDataStillNavigates() {
        let ticket = makeTicket()
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: HomeSourceStatus(check: .stale, failureReason: "refresh failed")
        ))
        model.openStory(ticket)
        XCTAssertEqual(actions, [.openJiraIssue(url: ticket.issueURL)])
    }

    // MARK: - Open review

    func testOpenReviewDeepLinksToMergeRequest() {
        let item = makeReviewItem()
        let model = makeModel(snapshot: HomeBoardSnapshot(
            reviewItems: [item],
            reviewStatus: .current
        ))
        model.openReview(item)
        XCTAssertEqual(actions, [.openMergeRequest(url: item.mergeRequestURL, list: .reviewsRequested)])
    }

    func testOpenReviewVanishedFromCurrentDataStaysAndNotices() {
        let item = makeReviewItem()
        let model = makeModel(snapshot: HomeBoardSnapshot(reviewItems: [], reviewStatus: .current))
        model.openReview(item)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(model.notice, HomeBoardModel.vanishedNotice)
    }

    // MARK: - Continue ticket

    func testContinueTicketOpensMatchedSession() async {
        let ticket = makeTicket(key: "PROJ-9")
        let session = ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: "S",
            workingDirectory: URL(fileURLWithPath: "/tmp/s"),
            terminalView: ConsoleTerminalView(),
            activity: .working,
            attention: .none,
            summary: nil,
            artifacts: [SessionArtifact(kind: .jiraIssue, label: "PROJ-9")],
            bridgeStatus: .unknown
        )
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: .current
        ))
        await model.continueTicket(ticket, sessions: [session])
        XCTAssertEqual(actions, [.selectSession(session.id)])
        XCTAssertTrue(launchedKeys.isEmpty)
    }

    func testContinueTicketWithoutSessionLaunchesOnCurrentData() async {
        let ticket = makeTicket(key: "PROJ-9")
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: .current
        ))
        await model.continueTicket(ticket, sessions: [])
        XCTAssertEqual(launchedKeys, ["PROJ-9"])
        XCTAssertTrue(actions.isEmpty)
    }

    func testContinueTicketOnStaleDataRequestsRefreshInsteadOfLaunching() async {
        let ticket = makeTicket(key: "PROJ-9")
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: HomeSourceStatus(check: .stale, failureReason: "refresh failed")
        ))
        await model.continueTicket(ticket, sessions: [])
        XCTAssertTrue(launchedKeys.isEmpty)
        XCTAssertEqual(refreshCount, 1)
    }

    func testContinueTicketStillOpensSessionFromRetainedData() async {
        let ticket = makeTicket(key: "PROJ-9")
        let session = ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: "S",
            workingDirectory: URL(fileURLWithPath: "/tmp/s"),
            terminalView: ConsoleTerminalView(),
            activity: .idle,
            attention: .none,
            summary: nil,
            artifacts: [SessionArtifact(kind: .jiraIssue, label: "PROJ-9")],
            bridgeStatus: .unknown
        )
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: HomeSourceStatus(check: .stale, failureReason: "refresh failed")
        ))
        await model.continueTicket(ticket, sessions: [session])
        XCTAssertEqual(actions, [.selectSession(session.id)])
        XCTAssertEqual(refreshCount, 0)
    }

    func testContinueTicketVanishedFromCurrentDataNotices() async {
        let ticket = makeTicket(key: "PROJ-9")
        let model = makeModel(snapshot: HomeBoardSnapshot(jiraTickets: [], jiraStatus: .current))
        await model.continueTicket(ticket, sessions: [])
        XCTAssertTrue(launchedKeys.isEmpty)
        XCTAssertEqual(model.notice, HomeBoardModel.vanishedNotice)
    }

    func testDuplicateLaunchWhileInFlightIsDropped() async {
        let ticket = makeTicket(key: "PROJ-9")
        let model = HomeBoardModel(
            jiraController: JiraPanelController(),
            reviewsController: MRReviewScanController(urlProvider: { "" })
        )
        model.snapshotHandler = {
            HomeBoardSnapshot(jiraTickets: [ticket], jiraStatus: .current)
        }
        var launchCompletions = 0
        model.startSessionHandler = { _, _, _ in
            // While the first launch is awaiting, a duplicate call must be
            // dropped; then let the first finish.
            XCTAssertEqual(model.launchingTicketKeys, ["PROJ-9"])
            let second = Task { await model.continueTicket(ticket, sessions: []) }
            await second.value
            XCTAssertEqual(self.launchedKeys.isEmpty, true)
            launchCompletions += 1
        }
        await model.continueTicket(ticket, sessions: [])
        XCTAssertEqual(launchCompletions, 1)
        XCTAssertTrue(model.launchingTicketKeys.isEmpty)
    }

    // MARK: - Notice

    func testSuccessfulActionClearsNotice() {
        let ticket = makeTicket()
        let model = makeModel(snapshot: HomeBoardSnapshot(
            jiraTickets: [ticket],
            jiraStatus: .current
        ))
        model.openStory(makeTicket(key: "GONE", status: "To Do", order: 9))
        XCTAssertEqual(model.notice, HomeBoardModel.vanishedNotice)
        model.openStory(ticket)
        XCTAssertNil(model.notice)
    }
}
