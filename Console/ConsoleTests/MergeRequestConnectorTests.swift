import XCTest
@testable import Console

@MainActor
final class MergeRequestConnectorTests: XCTestCase {
    private func makeSession(name: String, artifacts: [SessionArtifact] = []) -> ConsoleSession {
        ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: name,
            workingDirectory: URL(fileURLWithPath: "/tmp/connector"),
            terminalView: ConsoleTerminalView(),
            activity: .idle,
            attention: .none,
            summary: nil,
            artifacts: artifacts,
            bridgeStatus: .unknown,
            purpose: .review
        )
    }

    private func reviewItem(url: String, jiraKey: String?, title: String) -> MergeRequestSummary {
        MergeRequestSummary(
            id: URL(string: url)!,
            iidText: "7",
            title: title,
            projectDisplayName: "grp/proj",
            authorDisplayName: "author",
            isDraft: false,
            pipelineDisplayState: nil,
            reviewDisplayState: nil,
            updatedText: nil,
            mergeRequestURL: URL(string: url)!,
            sourceOrder: 0,
            triageCategory: .needsReview,
            triageReason: nil,
            jiraIssueKey: jiraKey
        )
    }

    private func authoredItem(url: String, jiraKey: String?, title: String) -> AuthoredMRAttention {
        AuthoredMRAttention(
            project: "grp/proj",
            iid: 7,
            url: URL(string: url)!,
            title: title,
            authorUsername: "me",
            state: "opened",
            unresolvedDiscussionCount: 0,
            externalApprovalCount: 0,
            approvalRulesSatisfied: true,
            jiraIssueKey: jiraKey
        )
    }

    func testCandidatesMatchReviewItemByJiraKeyFromSessionName() {
        let session = makeSession(name: "NMA-1234 Review")
        let item = reviewItem(
            url: "https://gitlab.example.test/grp/proj/-/merge_requests/7",
            jiraKey: "NMA-1234",
            title: "NMA-1234: fix the redirect"
        )

        let urls = MergeRequestConnector.candidates(
            for: session, associations: nil, reviewItems: [item], authoredItems: []
        )

        XCTAssertEqual(urls.map(\.absoluteString), ["https://gitlab.example.test/grp/proj/-/merge_requests/7"])
    }

    func testCandidatesMatchByTitleWhenTheTicketKeyIsMissing() {
        let session = makeSession(name: "NMA-1234")
        let item = reviewItem(
            url: "https://gitlab.example.test/grp/proj/-/merge_requests/7",
            jiraKey: nil,
            title: "NMA-1234: fix the redirect"
        )

        let urls = MergeRequestConnector.candidates(
            for: session, associations: nil, reviewItems: [item], authoredItems: []
        )

        XCTAssertEqual(urls.count, 1)
    }

    func testCandidatesDeduplicateTheSameMergeRequestAcrossSources() {
        let session = makeSession(name: "NMA-1234 Review")
        let url = "https://gitlab.example.test/grp/proj/-/merge_requests/7"
        let review = reviewItem(url: url, jiraKey: "NMA-1234", title: "NMA-1234")
        let authored = authoredItem(url: url, jiraKey: "NMA-1234", title: "NMA-1234")

        let urls = MergeRequestConnector.candidates(
            for: session, associations: nil, reviewItems: [review], authoredItems: [authored]
        )

        XCTAssertEqual(urls.count, 1)
    }

    func testCandidatesIgnoreUnrelatedTickets() {
        let session = makeSession(name: "NMA-1234 Review")
        let item = reviewItem(
            url: "https://gitlab.example.test/grp/proj/-/merge_requests/9",
            jiraKey: "NMA-9999",
            title: "NMA-9999: unrelated"
        )

        XCTAssertTrue(MergeRequestConnector.candidates(
            for: session, associations: nil, reviewItems: [item], authoredItems: []
        ).isEmpty)
    }

    func testSessionJiraKeyUsesArtifactThenName() {
        let nameOnly = makeSession(name: "NMA-1234 Review")
        XCTAssertEqual(MergeRequestConnector.sessionJiraKey(nameOnly), "NMA-1234")

        let artifact = SessionArtifact(kind: .jiraIssue, label: "ENG-42")
        let withArtifact = makeSession(name: "General", artifacts: [artifact])
        XCTAssertEqual(MergeRequestConnector.sessionJiraKey(withArtifact), "ENG-42")
    }

    func testMergeRequestURLValidation() {
        XCTAssertNotNil(MergeRequestConnector.mergeRequestURL(
            from: "https://gitlab.example.test/grp/proj/-/merge_requests/3"))
        XCTAssertNil(MergeRequestConnector.mergeRequestURL(
            from: "https://gitlab.example.test/grp/proj/-/issues/3"))
        XCTAssertNil(MergeRequestConnector.mergeRequestURL(from: "not a url"))
    }

    func testResolveMergeRequestURLDetectsURLOrNumber() {
        let candidates = [
            URL(string: "https://gitlab.example.test/grp/proj/-/merge_requests/7")!,
            URL(string: "https://gitlab.example.test/grp/other/-/merge_requests/9")!,
        ]

        // A full URL is used verbatim.
        XCTAssertEqual(
            MergeRequestConnector.resolveMergeRequestURL(
                from: "https://gitlab.example.test/grp/proj/-/merge_requests/42",
                candidates: candidates
            ),
            URL(string: "https://gitlab.example.test/grp/proj/-/merge_requests/42")
        )

        // A bare number matching a candidate returns that candidate verbatim.
        XCTAssertEqual(
            MergeRequestConnector.resolveMergeRequestURL(from: "9", candidates: candidates),
            candidates[1]
        )
        // `!`-prefixed numbers are accepted too.
        XCTAssertEqual(
            MergeRequestConnector.resolveMergeRequestURL(from: "!7", candidates: candidates),
            candidates[0]
        )

        // An unmatched number is built into the first candidate's project.
        XCTAssertEqual(
            MergeRequestConnector.resolveMergeRequestURL(from: "55", candidates: candidates),
            URL(string: "https://gitlab.example.test/grp/proj/-/merge_requests/55")
        )
    }

    func testResolveMergeRequestURLRejectsUnresolvableInput() {
        XCTAssertNil(MergeRequestConnector.resolveMergeRequestURL(from: "not a url", candidates: []))
        XCTAssertNil(MergeRequestConnector.resolveMergeRequestURL(from: "42", candidates: []))
        XCTAssertNil(MergeRequestConnector.resolveMergeRequestURL(from: "", candidates: []))
    }

    func testAttachableMergeRequestLabelIsNumberKeyTitle() {
        let withKey = AttachableMergeRequest(
            iid: "1234",
            jiraKey: "NMA-5678",
            title: "Fix the login redirect",
            url: URL(string: "https://gitlab.example.test/grp/proj/-/merge_requests/1234")!
        )
        XCTAssertEqual(withKey.label, "MR-1234, NMA-5678, Fix the login redirect")

        let withoutKey = AttachableMergeRequest(
            iid: "9",
            jiraKey: nil,
            title: "Tidy the build",
            url: URL(string: "https://gitlab.example.test/grp/proj/-/merge_requests/9")!
        )
        XCTAssertEqual(withoutKey.label, "MR-9, Tidy the build")
    }
}
