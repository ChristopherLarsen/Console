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
        id: UUID = UUID(),
        name: String,
        state: DisplayedSessionState,
        summary: String? = nil
    ) -> NextContextSnapshot.SessionInfo {
        NextContextSnapshot.SessionInfo(id: id, name: name, state: state, summary: summary)
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

    func testEmptySnapshotProducesNoWorkInLoadedLists() {
        let task = NextContextBuilder.recommendedTask(for: NextContextSnapshot())
        XCTAssertEqual(task.kind, .newTicket)
        XCTAssertEqual(task.headline, "No work in the loaded lists")
        XCTAssertNil(task.targetURL)
        XCTAssertEqual(task.openTarget, .source(.jira))
        XCTAssertNil(task.freshnessNote)
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
        XCTAssertEqual(
            task.openTarget,
            .jiraIssue(key: "SYN-41", url: URL(string: "https://jira.example.com/browse/SYN-41")!)
        )
    }

    func testSessionRecommendationKeepsExactSessionIdentity() {
        let sessionID = UUID()
        let snapshot = NextContextSnapshot(
            sessions: [session(id: sessionID, name: "Console work", state: .needsReview)]
        )

        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .sessionAttention)
        XCTAssertEqual(task.sessionName, "Console work")
        XCTAssertEqual(task.sessionID, sessionID)
        XCTAssertEqual(task.openTarget, .session(id: sessionID))
        XCTAssertNil(task.targetURL)
    }

    // MARK: - Honesty about availability and freshness

    func testSignedOutSourceDoesNotProduceUnqualifiedAllClear() {
        let snapshot = NextContextSnapshot(
            ticketsStatus: NextSourceStatus(check: .signedOut)
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.headline, "Could not check these sources")
        XCTAssertTrue(task.lines.contains("JIRA needs sign-in."))
        XCTAssertEqual(task.openTarget, .source(.jira))
        XCTAssertFalse(task.headline.localizedCaseInsensitiveContains("nothing needs you"))
    }

    func testUnconfiguredSourceDoesNotProduceUnqualifiedAllClear() {
        let snapshot = NextContextSnapshot(
            reviewsStatus: NextSourceStatus(check: .unconfigured),
            authoredStatus: NextSourceStatus(check: .unconfigured)
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.headline, "Could not check these sources")
        XCTAssertTrue(task.lines.contains("Reviews is not configured."))
        XCTAssertEqual(task.openTarget, .source(.reviews))
    }

    func testFailedSourceDoesNotProduceUnqualifiedAllClear() {
        let snapshot = NextContextSnapshot(
            ticketsStatus: NextSourceStatus(check: .failed, failureReason: "could not read list")
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.headline, "Could not check these sources")
        XCTAssertTrue(task.lines.contains("Could not read JIRA."))
        XCTAssertEqual(task.openTarget, .source(.jira))
    }

    func testLoadedEmptyListsProduceNoWorkCopy() {
        let snapshot = NextContextSnapshot(
            reviewsStatus: NextSourceStatus(check: .current, lastSuccessfulExtraction: Date()),
            authoredStatus: NextSourceStatus(check: .current, lastSuccessfulExtraction: Date()),
            ticketsStatus: NextSourceStatus(check: .current, lastSuccessfulExtraction: Date())
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.headline, "No work in the loaded lists")
        XCTAssertEqual(task.openTarget, .source(.jira))
    }

    func testStaleReviewIsLabelledOnce() {
        let snapshot = NextContextSnapshot(
            reviewItems: [mr(iid: "7", title: "Stale review", order: 0)],
            reviewsStatus: NextSourceStatus(
                check: .stale,
                lastSuccessfulExtraction: Date().addingTimeInterval(-600),
                failureReason: "Sign-in required"
            )
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .reviewMergeRequest)
        XCTAssertEqual(task.freshnessNote, NextContextBuilder.staleLabel)
        XCTAssertEqual(task.lines.filter { $0 == NextContextBuilder.staleLabel }.count, 0)
        XCTAssertEqual(task.targetURL?.absoluteString.contains("merge_requests/0"), true)
    }

    func testAllClearWithStaleSourceIsLabelledOnce() {
        let snapshot = NextContextSnapshot(
            authoredItems: [mr(title: "Fine", review: "Approved", order: 0)],
            authoredStatus: NextSourceStatus(check: .stale, lastSuccessfulExtraction: Date())
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.headline, "No work in the loaded lists")
        XCTAssertEqual(task.freshnessNote, NextContextBuilder.staleLabel)
    }

    func testPriorityStillPrefersReviewOverUnavailableJira() {
        let snapshot = NextContextSnapshot(
            reviewItems: [mr(title: "Their MR", order: 0)],
            ticketsStatus: NextSourceStatus(check: .signedOut)
        )
        let task = NextContextBuilder.recommendedTask(for: snapshot)
        XCTAssertEqual(task.kind, .reviewMergeRequest)
        XCTAssertNil(task.freshnessNote)
    }

    func testSourceStatusMappingFromJiraPanelStates() {
        XCTAssertEqual(NextSourceStatus.from(JiraPanelState.unconfigured).check, .unconfigured)
        XCTAssertEqual(NextSourceStatus.from(JiraPanelState.authenticationRequired).check, .signedOut)
        XCTAssertEqual(NextSourceStatus.from(JiraPanelState.extractionFailed).check, .failed)
        XCTAssertEqual(NextSourceStatus.from(JiraPanelState.unsupportedPage).check, .unsupported)
        XCTAssertTrue(NextSourceStatus.from(JiraPanelState.unconfigured).couldNotCheck)
        XCTAssertFalse(NextSourceStatus.from(JiraPanelState.loaded(tickets: [], refreshedAt: Date())).couldNotCheck)

        let stale = NextSourceStatus.from(
            JiraPanelState.stale(tickets: [], refreshedAt: Date(), reason: "could not read list")
        )
        XCTAssertEqual(stale.check, .stale)
        XCTAssertEqual(stale.failureReason, "could not read list")
        XCTAssertFalse(stale.couldNotCheck)
    }

    func testSourceStatusMappingFromMergeRequestPanelStates() {
        XCTAssertEqual(NextSourceStatus.from(MergeRequestListPanelState.unconfigured).check, .unconfigured)
        XCTAssertEqual(NextSourceStatus.from(MergeRequestListPanelState.authenticationRequired).check, .signedOut)
        XCTAssertEqual(NextSourceStatus.from(MergeRequestListPanelState.extractionFailed).check, .failed)
        let stale = NextSourceStatus.from(
            MergeRequestListPanelState.stale(
                items: [],
                refreshedAt: Date(),
                reason: .signInRequired
            )
        )
        XCTAssertEqual(stale.check, .stale)
        XCTAssertEqual(stale.failureReason, "Sign-in required")
    }
}
