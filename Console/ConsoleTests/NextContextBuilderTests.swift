import XCTest
@testable import Console

final class NextContextBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func mr(
        iid: String = "1",
        title: String,
        project: String? = "Repo",
        author: String? = "Someone Else",
        isDraft: Bool = false,
        pipeline: String? = nil,
        review: String? = nil,
        order: Int
    ) -> MergeRequestSummary {
        let url = URL(string: "https://gitlab.example.com/p/r/-/merge_requests/\(order)")!
        return MergeRequestSummary(
            id: url,
            iidText: iid,
            title: title,
            projectDisplayName: project,
            authorDisplayName: author,
            isDraft: isDraft,
            pipelineDisplayState: pipeline,
            reviewDisplayState: review,
            updatedText: nil,
            mergeRequestURL: url,
            sourceOrder: order
        )
    }

    private func session(
        name: String,
        state: DisplayedSessionState,
        summary: String? = nil
    ) -> NextContextSnapshot.SessionInfo {
        NextContextSnapshot.SessionInfo(name: name, state: state, summary: summary)
    }

    private func ticket(
        key: String,
        status: String?,
        order: Int
    ) -> JiraTicketSummary {
        JiraTicketSummary(
            key: key,
            summary: "Do \(key)",
            status: status,
            priority: nil,
            updatedText: nil,
            issueURL: URL(string: "https://jira.example.com/browse/\(key)")!,
            sourceOrder: order
        )
    }

    // MARK: - Priority order

    func testReviewListWinsOverEverything() {
        let snapshot = NextContextSnapshot(
            reviewItems: [mr(title: "Their MR", order: 0)],
            authoredItems: [mr(title: "My MR", review: "Changes requested", order: 1)],
            sessions: [session(name: "Blocked One", state: .needsApproval)],
            tickets: [ticket(key: "PROJ-1", status: "To Do", order: 2)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .reviewMergeRequest)
        XCTAssertEqual(task.targetURL?.absoluteString.contains("merge_requests/0"), true)
    }

    func testNeedsYouAuthoredMRBeatsSessionAttention() {
        let snapshot = NextContextSnapshot(
            authoredItems: [
                mr(title: "Clean one", review: "Approved", order: 5),
                mr(title: "Needs my work", review: "Changes requested", order: 6),
                mr(title: "Also mine", pipeline: "failed", order: 7)
            ],
            sessions: [session(name: "Antivirus", state: .needsInput)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .addressComments)
        // The first needs-you MR in host order wins (changes-requested at 6,
        // not the failed pipeline at 7).
        XCTAssertEqual(task.targetURL?.absoluteString.contains("merge_requests/6"), true)
    }

    func testNonNeedsYouAuthoredMRsAreSkipped() {
        let snapshot = NextContextSnapshot(
            authoredItems: [mr(title: "Fine", review: "Approved", order: 3)],
            sessions: [session(name: "Console work", state: .needsReview)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .sessionAttention)
        XCTAssertEqual(task.sessionName, "Console work")
    }

    func testSessionAttentionBeatsTicket() {
        let snapshot = NextContextSnapshot(
            sessions: [session(name: "S", state: .blocked, summary: "Waiting on API keys")],
            tickets: [ticket(key: "PROJ-9", status: "To Do", order: 0)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .sessionAttention)
        XCTAssertEqual(task.lines.first, "Waiting on API keys")
    }

    func testParkedTicketChosenByHostOrder() {
        let snapshot = NextContextSnapshot(
            tickets: [
                ticket(key: "PROJ-8", status: "In Progress", order: 0),
                ticket(key: "PROJ-4", status: "To Do", order: 1),
                ticket(key: "PROJ-2", status: "Backlog", order: 2)
            ]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .newTicket)
        XCTAssertEqual(task.headline, "Start PROJ-4")
    }

    func testEmptySnapshotProducesQuietNewTicketTask() {
        let task = NextContextBuilder.recommendedTask(for: NextContextSnapshot())
        XCTAssertEqual(task.kind, .newTicket)
        XCTAssertFalse(task.headline.isEmpty)
        XCTAssertNil(task.targetURL)
    }

    // MARK: - Session ordering

    func testFirstNeedingSessionWins() {
        let snapshot = NextContextSnapshot(
            sessions: [
                session(name: "Working", state: .working),
                session(name: "Approval", state: .needsApproval),
                session(name: "Input", state: .needsInput)
            ]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.sessionName, "Approval")
    }

    // MARK: - Local-only selection

    func testSyntheticReviewProducesRecommendationWithoutProvider() {
        let snapshot = NextContextSnapshot(
            reviewItems: [mr(iid: "88", title: "Fix placement", project: "AntivirusGodot", order: 0)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .reviewMergeRequest)
        XCTAssertEqual(task.headline, "Review !88 in AntivirusGodot")
        XCTAssertEqual(task.targetURL?.absoluteString, "https://gitlab.example.com/p/r/-/merge_requests/0")
        XCTAssertNil(task.sessionName)
    }

    func testSyntheticParkedTicketKeepsIssueDeepLink() {
        let snapshot = NextContextSnapshot(
            tickets: [ticket(key: "SYN-41", status: "To Do", order: 0)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .newTicket)
        XCTAssertEqual(task.headline, "Start SYN-41")
        XCTAssertEqual(task.targetURL?.absoluteString, "https://jira.example.com/browse/SYN-41")
    }

    func testSessionRecommendationKeepsExactSessionName() {
        let snapshot = NextContextSnapshot(
            sessions: [session(name: "Console work", state: .needsReview)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .sessionAttention)
        XCTAssertEqual(task.sessionName, "Console work")
        XCTAssertNil(task.targetURL)
    }
}
