import XCTest
@testable import Console

/// Pure selection rules for the Home work board: next story, in-progress
/// filter, awaiting-author review filter, and health mapping from
/// `NextSourceStatus` including retained-data upgrades.
final class HomeBoardBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func ticket(
        key: String = "PROJ-1",
        status: String?,
        order: Int
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

    private func reviewItem(
        iid: String = "1",
        reviewState: String?,
        pipeline: String? = nil,
        order: Int
    ) -> MergeRequestSummary {
        MergeRequestSummary(
            id: URL(string: "https://gitlab.example.test/p/r/-/merge_requests/\(iid)")!,
            iidText: iid,
            title: "MR \(iid)",
            projectDisplayName: "Project",
            authorDisplayName: nil,
            isDraft: false,
            pipelineDisplayState: pipeline,
            reviewDisplayState: reviewState,
            updatedText: nil,
            mergeRequestURL: URL(string: "https://gitlab.example.test/p/r/-/merge_requests/\(iid)")!,
            sourceOrder: order
        )
    }

    // MARK: - Next story

    func testNextStoryIsFirstParkedTicketInSourceOrder() {
        let tickets = [
            ticket(key: "A", status: "In Progress", order: 0),
            ticket(key: "B", status: "To Do", order: 1),
            ticket(key: "C", status: "Backlog", order: 2),
        ]
        XCTAssertEqual(HomeBoardBuilder.nextStoryTicket(in: tickets)?.key, "B")
    }

    func testUnknownStatusVocabularyParksAndIsEligibleToStart() {
        let tickets = [
            ticket(key: "A", status: "In Progress", order: 0),
            ticket(key: "B", status: "Mystery Status", order: 1),
        ]
        XCTAssertEqual(HomeBoardBuilder.nextStoryTicket(in: tickets)?.key, "B")
    }

    func testNextStoryIsNilWhenEveryTicketIsBusyOrDone() {
        let tickets = [
            ticket(key: "A", status: "In Progress", order: 0),
            ticket(key: "B", status: "Done", order: 1),
        ]
        XCTAssertNil(HomeBoardBuilder.nextStoryTicket(in: tickets))
    }

    // MARK: - In progress

    func testInProgressKeepsOnlyActiveVocabularyInHostOrder() {
        let tickets = [
            ticket(key: "A", status: "In Progress", order: 0),
            ticket(key: "B", status: "To Do", order: 1),
            ticket(key: "C", status: "In Development", order: 2),
            ticket(key: "D", status: "Blocked", order: 3),
        ]
        let snapshot = HomeBoardSnapshot(jiraTickets: tickets, jiraStatus: .current)
        let board = HomeBoardBuilder.build(snapshot)
        XCTAssertEqual(board.inProgressTickets.map(\.key), ["A", "C"])
    }

    // MARK: - Awaiting author

    func testAwaitingAuthorKeepsChangesRequestedAndDiscussionOnly() {
        let items = [
            reviewItem(iid: "1", reviewState: "Changes requested", order: 0),
            reviewItem(iid: "2", reviewState: "Discussion", order: 1),
            reviewItem(iid: "3", reviewState: "Approved", order: 2),
            reviewItem(iid: "4", reviewState: nil, pipeline: "Passed", order: 3),
        ]
        let snapshot = HomeBoardSnapshot(reviewItems: items, reviewStatus: .current)
        let board = HomeBoardBuilder.build(snapshot)
        XCTAssertEqual(board.awaitingAuthorRequests.map { $0.iidText }, ["1", "2"])
    }

    func testNextReviewIsFirstRowRegardlessOfReviewState() {
        let items = [
            reviewItem(iid: "1", reviewState: "Approved", order: 0),
            reviewItem(iid: "2", reviewState: "Changes requested", order: 1),
        ]
        let snapshot = HomeBoardSnapshot(reviewItems: items, reviewStatus: .current)
        let board = HomeBoardBuilder.build(snapshot)
        XCTAssertEqual(board.nextReview?.iidText, "1")
    }

    // MARK: - Health mapping

    func testPendingWithoutRetainedDataLoads() {
        let health = HomeBoardBuilder.health(for: NextSourceStatus(check: .pending), hasRetained: false)
        XCTAssertEqual(health, .loading)
    }

    func testPendingWithRetainedDataUpdates() {
        let health = HomeBoardBuilder.health(for: NextSourceStatus(check: .pending), hasRetained: true)
        XCTAssertEqual(health, .updating)
    }

    func testFailedOrUnsupportedWithoutRetainedDataIsUnavailable() {
        XCTAssertEqual(
            HomeBoardBuilder.health(for: NextSourceStatus(check: .failed), hasRetained: false),
            .unavailable
        )
        XCTAssertEqual(
            HomeBoardBuilder.health(for: NextSourceStatus(check: .unsupported), hasRetained: false),
            .unavailable
        )
    }

    func testFailedOrUnsupportedWithRetainedDataStaysStale() {
        XCTAssertEqual(
            HomeBoardBuilder.health(
                for: NextSourceStatus(check: .failed, failureReason: "could not read list"),
                hasRetained: true
            ),
            .stale(reason: "could not read list")
        )
        XCTAssertEqual(
            HomeBoardBuilder.health(for: NextSourceStatus(check: .unsupported), hasRetained: true),
            .stale(reason: nil)
        )
    }

    func testCurrentWithNoEligibleItemsStillReady() {
        let snapshot = HomeBoardSnapshot(jiraTickets: [], jiraStatus: .current)
        let board = HomeBoardBuilder.build(snapshot)
        XCTAssertEqual(board.jiraHealth, .ready)
        XCTAssertNil(board.nextStory)
        XCTAssertTrue(board.inProgressTickets.isEmpty)
    }

    func testUnconfiguredAndSignedOutMapDirectly() {
        XCTAssertEqual(
            HomeBoardBuilder.health(for: NextSourceStatus(check: .unconfigured), hasRetained: false),
            .unconfigured
        )
        XCTAssertEqual(
            HomeBoardBuilder.health(for: NextSourceStatus(check: .signedOut), hasRetained: true),
            .signedOut
        )
    }

    // MARK: - Launch gating

    func testStartSessionRequiresCurrentData() {
        XCTAssertTrue(HomeBoardBuilder.canStartSession(jiraStatus: .current))
        XCTAssertFalse(HomeBoardBuilder.canStartSession(
            jiraStatus: NextSourceStatus(check: .stale, failureReason: "refresh failed")
        ))
        XCTAssertFalse(HomeBoardBuilder.canStartSession(jiraStatus: NextSourceStatus(check: .pending)))
    }
}
