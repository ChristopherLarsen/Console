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
