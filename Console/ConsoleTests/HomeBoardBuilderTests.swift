import XCTest
@testable import Console

/// Pure selection and ordering rules for the Home work board: next story,
/// in-progress filter, review-queue urgency order, and health mapping from
/// `HomeSourceStatus` including retained-data upgrades.
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
        updated: String? = nil,
        targetVersion: String? = nil,
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
            updatedText: updated,
            targetVersionText: targetVersion,
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

    // MARK: - Review queue ordering

    func testReviewQueueKeepsEveryRow() {
        let items = [
            reviewItem(iid: "1", reviewState: "Changes requested", order: 0),
            reviewItem(iid: "2", reviewState: "Discussion", order: 1),
            reviewItem(iid: "3", reviewState: "Approved", order: 2),
            reviewItem(iid: "4", reviewState: nil, pipeline: "Passed", order: 3),
        ]
        let snapshot = HomeBoardSnapshot(reviewItems: items, reviewStatus: .current)
        let board = HomeBoardBuilder.build(snapshot)
        XCTAssertEqual(board.reviewQueue.map { $0.iidText }, ["1", "2", "3", "4"])
    }

    func testReReviewsSortAboveNeverReviewedRegardlessOfAge() {
        let items = [
            reviewItem(iid: "1", reviewState: "Review requested", updated: "4 weeks ago", order: 0),
            reviewItem(iid: "2", reviewState: "Changes requested", updated: "3 days ago", order: 1),
            reviewItem(iid: "3", reviewState: "Discussion", updated: "now", order: 2),
        ]
        XCTAssertEqual(HomeBoardBuilder.reviewQueue(in: items).map { $0.iidText }, ["2", "3", "1"])
    }

    func testOlderRowsSortAboveNewerWithinTierWhenVersionsMatch() {
        let items = [
            reviewItem(iid: "1", reviewState: nil, updated: "2 days ago", targetVersion: "1.0", order: 0),
            reviewItem(iid: "2", reviewState: nil, updated: "3 weeks ago", targetVersion: "1.0", order: 1),
            reviewItem(iid: "3", reviewState: nil, updated: "2 hours ago", targetVersion: "1.0", order: 2),
        ]
        XCTAssertEqual(HomeBoardBuilder.reviewQueue(in: items).map { $0.iidText }, ["2", "1", "3"])
    }

    func testTargetVersionOutranksAgeWithinTier() {
        let items = [
            reviewItem(iid: "1", reviewState: nil, updated: "3 weeks ago", targetVersion: "2.0", order: 0),
            reviewItem(iid: "2", reviewState: nil, updated: "2 hours ago", targetVersion: "1.0", order: 1),
        ]
        XCTAssertEqual(HomeBoardBuilder.reviewQueue(in: items).map { $0.iidText }, ["2", "1"])
    }

    func testLowerTargetVersionSortsAboveHigherNumerically() {
        let items = [
            reviewItem(iid: "1", reviewState: nil, targetVersion: "1.10", order: 0),
            reviewItem(iid: "2", reviewState: nil, targetVersion: "1.9", order: 1),
            reviewItem(iid: "3", reviewState: nil, targetVersion: "24.10", order: 2),
            reviewItem(iid: "4", reviewState: nil, targetVersion: "24.9", order: 3),
        ]
        XCTAssertEqual(HomeBoardBuilder.reviewQueue(in: items).map { $0.iidText }, ["2", "1", "4", "3"])
    }

    func testMissingTargetVersionSortsLastWithinTie() {
        let items = [
            reviewItem(iid: "1", reviewState: nil, targetVersion: nil, order: 0),
            reviewItem(iid: "2", reviewState: nil, targetVersion: "2.0", order: 1),
        ]
        XCTAssertEqual(HomeBoardBuilder.reviewQueue(in: items).map { $0.iidText }, ["2", "1"])
    }

    func testHostOrderBreaksRemainingTies() {
        let items = [
            reviewItem(iid: "7", reviewState: nil, order: 1),
            reviewItem(iid: "5", reviewState: nil, order: 0),
        ]
        XCTAssertEqual(HomeBoardBuilder.reviewQueue(in: items).map { $0.iidText }, ["5", "7"])
    }

    func testCompareTargetVersionsIsNumericallyAware() {
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions("1.9", "1.10"), .orderedAscending)
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions("v1.2", "1.2.1"), .orderedAscending)
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions("24.10", "24.9"), .orderedDescending)
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions("1.2", "1.2"), .orderedSame)
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions(nil, "1.0"), .orderedDescending)
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions(nil, nil), .orderedSame)
        XCTAssertEqual(HomeBoardBuilder.compareTargetVersions("M120", "M119"), .orderedDescending)
    }

    // MARK: - Health mapping

    func testPendingWithoutRetainedDataLoads() {
        let health = HomeBoardBuilder.health(for: HomeSourceStatus(check: .pending), hasRetained: false)
        XCTAssertEqual(health, .loading)
    }

    func testPendingWithRetainedDataUpdates() {
        let health = HomeBoardBuilder.health(for: HomeSourceStatus(check: .pending), hasRetained: true)
        XCTAssertEqual(health, .updating)
    }

    func testFailedOrUnsupportedWithoutRetainedDataIsUnavailable() {
        XCTAssertEqual(
            HomeBoardBuilder.health(for: HomeSourceStatus(check: .failed), hasRetained: false),
            .unavailable
        )
        XCTAssertEqual(
            HomeBoardBuilder.health(for: HomeSourceStatus(check: .unsupported), hasRetained: false),
            .unavailable
        )
    }

    func testFailedOrUnsupportedWithRetainedDataStaysStale() {
        XCTAssertEqual(
            HomeBoardBuilder.health(
                for: HomeSourceStatus(check: .failed, failureReason: "could not read list"),
                hasRetained: true
            ),
            .stale(reason: "could not read list")
        )
        XCTAssertEqual(
            HomeBoardBuilder.health(for: HomeSourceStatus(check: .unsupported), hasRetained: true),
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
            HomeBoardBuilder.health(for: HomeSourceStatus(check: .unconfigured), hasRetained: false),
            .unconfigured
        )
        XCTAssertEqual(
            HomeBoardBuilder.health(for: HomeSourceStatus(check: .signedOut), hasRetained: true),
            .signedOut
        )
    }

    // MARK: - Launch gating

    func testStartSessionRequiresCurrentData() {
        XCTAssertTrue(HomeBoardBuilder.canStartSession(jiraStatus: .current))
        XCTAssertFalse(HomeBoardBuilder.canStartSession(
            jiraStatus: HomeSourceStatus(check: .stale, failureReason: "refresh failed")
        ))
        XCTAssertFalse(HomeBoardBuilder.canStartSession(jiraStatus: HomeSourceStatus(check: .pending)))
    }
}
