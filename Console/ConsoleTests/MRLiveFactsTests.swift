import XCTest
@testable import Console

final class MRLiveFactsTests: XCTestCase {
    private let url = URL(string: "https://gitlab.example.com:8443/group/sub/app/-/merge_requests/4035")!

    func testTargetEncodesTheProjectPathAndUsesOnlyGETs() throws {
        let target = try XCTUnwrap(MRLiveFactsParser.target(for: url))
        XCTAssertEqual(target.hostname, "gitlab.example.com:8443")
        XCTAssertEqual(target.endpoint, "projects/group%2Fsub%2Fapp/merge_requests/4035")
        let calls = MRLiveFactsParser.arguments(for: target)
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { Array($0.prefix(3)) == ["api", "--method", "GET"] })
        XCTAssertNil(MRLiveFactsParser.target(for: URL(string: "https://gitlab.example.com/group/app/-/issues/3")!))
    }

    func testFactsReadApprovalReviewerStateAndOwnUnresolvedThreads() throws {
        let facts = try XCTUnwrap(MRLiveFactsParser.facts(
            mergeRequest: Data(#"{"state":"opened","sha":"abc123"}"#.utf8),
            approvals: Data(#"{"approved_by":[{"user":{"username":"alex"}}]}"#.utf8),
            reviewers: Data(#"[{"user":{"username":"Me"},"state":"unreviewed"}]"#.utf8),
            discussions: Data("""
            [{"notes":[{"author":{"username":"me"},"resolvable":true,"resolved":false}]},
             {"notes":[{"author":{"username":"me"},"resolvable":true,"resolved":true}]},
             {"notes":[{"author":{"username":"alex"},"resolvable":true,"resolved":false}]}]
            """.utf8),
            username: "me", now: Date()
        ))
        XCTAssertEqual(facts.state, "opened")
        XCTAssertEqual(facts.headSHA, "abc123")
        XCTAssertEqual(facts.approvedBy, ["alex"])
        XCTAssertEqual(facts.approvedByMe, false)
        XCTAssertEqual(facts.myReviewerState, "unreviewed")
        XCTAssertEqual(facts.myUnresolvedThreads, 1)
    }

    func testFailedCallsStayUnknownInsteadOfReadingAsNo() throws {
        XCTAssertNil(MRLiveFactsParser.facts(mergeRequest: nil, approvals: nil, reviewers: nil, discussions: nil,
                                             username: "me", now: Date()))
        let facts = try XCTUnwrap(MRLiveFactsParser.facts(
            mergeRequest: Data(#"{"state":"opened","sha":"abc123"}"#.utf8), approvals: nil,
            reviewers: Data("[]".utf8), discussions: nil, username: "me", now: Date()
        ))
        XCTAssertNil(facts.approvedBy)
        XCTAssertNil(facts.approvedByMe)
        XCTAssertNil(facts.myUnresolvedThreads)
        XCTAssertEqual(facts.myReviewerState, "not a reviewer")
        XCTAssertTrue(facts.briefText(now: Date()).contains("approvals unknown"))
    }

    @MainActor
    func testStoreRefreshRunsReadOnlyCallsAndDropsItemsThatLeft() async throws {
        let store = MRLiveFactsStore { _, arguments, _ in
            guard Array(arguments.prefix(3)) == ["api", "--method", "GET"], let endpoint = arguments.last else { return nil }
            if endpoint.hasSuffix("/approvals") { return Data(#"{"approved_by":[{"user":{"username":"me"}}]}"#.utf8) }
            if endpoint.contains("/reviewers") || endpoint.contains("/discussions") { return Data("[]".utf8) }
            return Data(#"{"state":"opened","sha":"abc123"}"#.utf8)
        }
        let item = MergeRequestSummary(
            id: url, iidText: "4035", title: "T", projectDisplayName: nil, authorDisplayName: nil, isDraft: false,
            pipelineDisplayState: nil, reviewDisplayState: nil, updatedText: nil, mergeRequestURL: url, sourceOrder: 0
        )
        await store.refresh(items: [item], username: "me", executable: "/usr/bin/true", budget: 5)
        XCTAssertEqual(store.facts[url]?.approvedByMe, true)
        await store.refresh(items: [], username: "me", executable: "/usr/bin/true", budget: 5)
        XCTAssertTrue(store.facts.isEmpty)
    }
}
