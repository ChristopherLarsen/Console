import XCTest
@testable import Console

final class NextTaskNavigationTests: XCTestCase {

    private func mr(order: Int) -> MergeRequestSummary {
        let url = URL(string: "https://gitlab.example.com/p/r/-/merge_requests/\(order)")!
        return MergeRequestSummary(
            id: url,
            iidText: "\(order)",
            title: "Synthetic MR \(order)",
            projectDisplayName: "FixtureRepo",
            authorDisplayName: "Someone Else",
            isDraft: false,
            pipelineDisplayState: nil,
            reviewDisplayState: nil,
            updatedText: nil,
            mergeRequestURL: url,
            sourceOrder: order
        )
    }

    private func ticket(key: String) -> JiraTicketSummary {
        JiraTicketSummary(
            key: key,
            summary: "Do \(key)",
            status: "To Do",
            priority: nil,
            updatedText: nil,
            issueURL: URL(string: "https://jira.example.com/browse/\(key)")!,
            sourceOrder: 0
        )
    }

    func testSelectingSyntheticTicketOpensExactIssueURL() {
        let item = ticket(key: "SYN-14")
        let task = NextContextBuilder.recommendedTask(
            for: NextContextSnapshot(tickets: [item])
        )
        let decision = NextTaskNavigation.decide(
            task: task,
            snapshot: NextContextSnapshot(tickets: [item]),
            liveSessionStates: [:]
        )

        guard case .navigate(let plan) = decision else {
            return XCTFail("Expected navigation to the captured issue")
        }
        XCTAssertEqual(plan.destination, .jira)
        XCTAssertEqual(plan.jiraIssueURL, item.issueURL)
        XCTAssertNil(plan.mergeRequestURL)
        XCTAssertNil(plan.sessionID)
    }

    func testMissingSessionIDDoesNotSelectAnotherSession() {
        let missing = UUID()
        let other = UUID()
        let task = NextTask(
            kind: .sessionAttention,
            headline: "Needs Input: Ghost",
            lines: ["Waiting"],
            sessionName: "Ghost",
            sessionID: missing,
            openTarget: .session(id: missing)
        )
        let snapshot = NextContextSnapshot(
            sessions: [
                NextContextSnapshot.SessionInfo(id: other, name: "Ghost", state: .needsInput)
            ]
        )

        let decision = NextTaskNavigation.decide(
            task: task,
            snapshot: snapshot,
            liveSessionStates: [other: .needsInput]
        )

        guard case .stay(let updated) = decision else {
            return XCTFail("Missing session IDs must not navigate to another session")
        }
        XCTAssertEqual(updated.openTarget, .source(.sessions))
        XCTAssertNil(updated.sessionID)
        if case .session = updated.resolvedOpenTarget {
            XCTFail("Replacement must not target a session id")
        }
    }

    func testGoneSessionThenOpenSourceDoesNotCarryASessionID() {
        let missing = UUID()
        let task = NextTask(
            kind: .sessionAttention,
            headline: "Needs Input: Ghost",
            lines: ["Waiting"],
            sessionID: missing,
            openTarget: .session(id: missing)
        )
        guard case .stay(let updated) = NextTaskNavigation.decide(
            task: task,
            snapshot: NextContextSnapshot(),
            liveSessionStates: [:]
        ) else {
            return XCTFail("Expected stay when the session is gone")
        }

        guard case .navigate(let plan) = NextTaskNavigation.decide(
            task: updated,
            snapshot: NextContextSnapshot(),
            liveSessionStates: [UUID(): .needsInput]
        ) else {
            return XCTFail("Open source should navigate to Sessions")
        }
        XCTAssertEqual(plan.destination, .sessions)
        XCTAssertNil(plan.sessionID)
        XCTAssertTrue(plan.clearSessionSelection)
    }

    func testMissingMergeRequestOpensSourceInsteadOfAnotherMR() {
        let original = mr(order: 3)
        let other = mr(order: 9)
        let task = NextContextBuilder.recommendedTask(
            for: NextContextSnapshot(reviewItems: [original])
        )
        let decision = NextTaskNavigation.decide(
            task: task,
            snapshot: NextContextSnapshot(reviewItems: [other]),
            liveSessionStates: [:]
        )
        guard case .stay(let updated) = decision else {
            return XCTFail("A vanished MR must not open a different MR")
        }
        XCTAssertEqual(updated.openTarget, .source(.reviews))
        XCTAssertNil(updated.targetURL)
    }

    func testSessionThatLeftActionableStateIsNotOpened() {
        let id = UUID()
        let task = NextTask(
            kind: .sessionAttention,
            headline: "Needs Input: Done now",
            lines: ["Waiting"],
            sessionID: id,
            openTarget: .session(id: id)
        )
        let decision = NextTaskNavigation.decide(
            task: task,
            snapshot: NextContextSnapshot(
                sessions: [NextContextSnapshot.SessionInfo(id: id, name: "Done now", state: .working)]
            ),
            liveSessionStates: [id: .working]
        )
        guard case .stay = decision else {
            return XCTFail("A session that is no longer needs-you must not be opened")
        }
    }

    /// An authored MR that no longer asks the author for work must not be
    /// opened under the stale "Address feedback" imperative.
    func testAuthoredMergeRequestNoLongerNeedsYouStays() {
        let url = URL(string: "https://gitlab.example.com/p/r/-/merge_requests/3")!
        func authored(_ review: String) -> MergeRequestSummary {
            MergeRequestSummary(
                id: url,
                iidText: "3",
                title: "Synthetic MR",
                projectDisplayName: nil,
                authorDisplayName: nil,
                isDraft: false,
                pipelineDisplayState: nil,
                reviewDisplayState: review,
                updatedText: nil,
                mergeRequestURL: url,
                sourceOrder: 0
            )
        }
        let task = NextTask(
            kind: .addressComments,
            headline: "Address feedback on !3",
            lines: ["Comments"],
            targetURL: url,
            openTarget: .mergeRequest(url: url, list: .authored)
        )

        // Still needs-you: navigates.
        let actionable = NextContextSnapshot(authoredItems: [authored("Changes requested")])
        guard case .navigate = NextTaskNavigation.decide(task: task, snapshot: actionable, liveSessionStates: [:]) else {
            return XCTFail("A still-needs-you authored MR opens")
        }

        // Mutated to Approved under the old imperative: stay.
        let approved = NextContextSnapshot(authoredItems: [authored("Approved")])
        guard case .stay = NextTaskNavigation.decide(task: task, snapshot: approved, liveSessionStates: [:]) else {
            return XCTFail("An approved MR must not be opened under the address-comments imperative")
        }
    }

    /// A ticket that moved on (Done) must not be opened under the stale
    /// imperative; parked and blocked tickets remain openable.
    func testTicketNoLongerSelectableStays() {
        let issueURL = URL(string: "https://jira.example.com/browse/SYN-77")!
        func task() -> NextTask {
            NextTask(
                kind: .newTicket,
                headline: "Start SYN-77",
                lines: ["Do SYN-77"],
                targetURL: issueURL,
                openTarget: .jiraIssue(key: "SYN-77", url: issueURL)
            )
        }
        func ticket(status: String) -> JiraTicketSummary {
            JiraTicketSummary(
                key: "SYN-77",
                summary: "Do SYN-77",
                status: status,
                priority: nil,
                updatedText: nil,
                issueURL: issueURL,
                sourceOrder: 0
            )
        }

        guard case .navigate = NextTaskNavigation.decide(
            task: task(),
            snapshot: NextContextSnapshot(tickets: [ticket(status: "To Do")]),
            liveSessionStates: [:]
        ) else {
            return XCTFail("A still-parked ticket opens")
        }
        guard case .navigate = NextTaskNavigation.decide(
            task: task(),
            snapshot: NextContextSnapshot(tickets: [ticket(status: "Blocked")]),
            liveSessionStates: [:]
        ) else {
            return XCTFail("A blocked ticket Next picked still opens")
        }
        guard case .stay = NextTaskNavigation.decide(
            task: task(),
            snapshot: NextContextSnapshot(tickets: [ticket(status: "Done")]),
            liveSessionStates: [:]
        ) else {
            return XCTFail("A done ticket must not be opened under the start imperative")
        }
    }

    func testParserSessionTaskWithoutIDOpensSessionsSource() {
        let task = NextTask(
            kind: .sessionAttention,
            headline: "Needs Input: Named",
            lines: ["Waiting"],
            sessionName: "Named"
        )
        XCTAssertEqual(task.resolvedOpenTarget, .source(.sessions))
        guard case .navigate(let plan) = NextTaskNavigation.decide(
            task: task,
            snapshot: NextContextSnapshot(
                sessions: [NextContextSnapshot.SessionInfo(name: "Named", state: .needsInput)]
            ),
            liveSessionStates: [UUID(): .needsInput]
        ) else {
            return XCTFail("Name-only session tasks must open the Sessions source")
        }
        XCTAssertEqual(plan.destination, .sessions)
        XCTAssertNil(plan.sessionID)
        XCTAssertTrue(plan.clearSessionSelection)
    }
}
