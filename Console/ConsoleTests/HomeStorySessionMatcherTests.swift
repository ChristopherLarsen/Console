import XCTest
import SwiftTerm
@testable import Console

/// Session↔story matching for the In Progress column: artifact label/URL
/// matching, exited deprioritization, and the latest-store-order tie-break.
@MainActor
final class HomeStorySessionMatcherTests: XCTestCase {

    private var counter = 0

    private func makeSession(
        activity: SessionActivity = .idle,
        artifacts: [SessionArtifact]
    ) -> ConsoleSession {
        counter += 1
        return ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: "S\(counter)",
            workingDirectory: URL(fileURLWithPath: "/tmp/s\(counter)"),
            terminalView: ConsoleTerminalView(),
            activity: activity,
            attention: .none,
            summary: nil,
            artifacts: artifacts,
            bridgeStatus: .unknown
        )
    }

    private let issueURL = URL(string: "https://jira.example.test/browse/PROJ-9")!

    func testReviewMatchingScopesIIDToProjectAndPrefersLiveSession() {
        let url = URL(string: "https://gitlab.example.test/team/app/-/merge_requests/42")!
        var live = makeSession(artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42", url: url)])
        live.purpose = .review
        var exited = makeSession(activity: .exited, artifacts: live.artifacts)
        exited.purpose = .review
        var unrelated = makeSession(artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42",
            url: URL(string: "https://gitlab.example.test/team/other/-/merge_requests/42")!)])
        unrelated.purpose = .review
        let deepLink = URL(string: url.absoluteString + "/diffs?view=parallel#note_1")!
        XCTAssertEqual(HomeStorySessionMatcher.reviewSession(for: deepLink, in: [live, exited, unrelated])?.id, live.id)
        XCTAssertEqual(HomeStorySessionMatcher.reviewSession(for: url, in: [exited])?.id, exited.id)
        XCTAssertNil(HomeStorySessionMatcher.reviewSession(for: url, in: [unrelated]))
        live.purpose = .existingTicket
        XCTAssertNil(HomeStorySessionMatcher.reviewSession(for: url, in: [live]))
    }

    func testJiraNavigationUsesArtifactURLOrConfiguredContextPath() {
        let explicit = makeSession(artifacts: [.init(kind: .jiraIssue, label: "PROJ-9", url: issueURL)])
        XCTAssertEqual(HomeStorySessionMatcher.jiraURL(for: explicit, configuredURL: ""), issueURL)
        let keyOnly = makeSession(artifacts: [.init(kind: .jiraIssue, label: "proj-9")])
        XCTAssertEqual(HomeStorySessionMatcher.jiraURL(for: keyOnly,
            configuredURL: "https://jira.example.test/jira/secure/RapidBoard.jspa?rapidView=1")?.absoluteString,
            "https://jira.example.test/jira/browse/PROJ-9")
        XCTAssertNil(HomeStorySessionMatcher.jiraURL(for: keyOnly, configuredURL: ""))
    }

    func testJiraTitleResolutionRejectsAmbiguousStories() {
        XCTAssertEqual(JiraSourceContext.issueKey(in: "[PROJ-9] Fix login (PROJ-9)"), "PROJ-9")
        XCTAssertNil(JiraSourceContext.issueKey(in: "PROJ-9 and PROJ-10"))
        XCTAssertNil(JiraSourceContext.issueKey(in: "Fix login"))
        XCTAssertEqual(JiraSourceContext.issueURL(key: "PROJ-9",
            configuredURL: "https://jira.example.test/jira/software/projects/PROJ/boards/1")?.absoluteString,
            "https://jira.example.test/browse/PROJ-9")
    }

    // MARK: - Matching

    func testMatchesArtifactLabelCaseInsensitively() {
        let session = makeSession(artifacts: [SessionArtifact(kind: .jiraIssue, label: "proj-9")])
        XCTAssertEqual(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: nil, in: [session]),
            session.id
        )
    }

    func testMatchesArtifactURL() {
        let session = makeSession(artifacts: [
            SessionArtifact(kind: .jiraIssue, label: "SOMETHING-ELSE", url: issueURL)
        ])
        XCTAssertEqual(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: issueURL, in: [session]),
            session.id
        )
    }

    func testNonJiraArtifactsNeverMatch() {
        let session = makeSession(artifacts: [
            SessionArtifact(kind: .gitlabMergeRequest, label: "PROJ-9")
        ])
        XCTAssertNil(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: issueURL, in: [session])
        )
    }

    func testUnrelatedSessionsNeverMatch() {
        let sessions = [
            makeSession(artifacts: [SessionArtifact(kind: .jiraIssue, label: "OTHER-1")]),
            makeSession(artifacts: []),
        ]
        XCTAssertNil(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: issueURL, in: sessions)
        )
    }

    // MARK: - Ambiguity

    func testExitedMatchIsDeprioritizedForLiveMatch() {
        let exited = makeSession(activity: .exited, artifacts: [
            SessionArtifact(kind: .jiraIssue, label: "PROJ-9")
        ])
        let live = makeSession(activity: .working, artifacts: [
            SessionArtifact(kind: .jiraIssue, label: "PROJ-9")
        ])
        XCTAssertEqual(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: nil, in: [exited, live]),
            live.id
        )
    }

    func testLatestStoreOrderWinsAmongEqualLiveness() {
        let older = makeSession(artifacts: [SessionArtifact(kind: .jiraIssue, label: "PROJ-9")])
        let newer = makeSession(artifacts: [SessionArtifact(kind: .jiraIssue, label: "PROJ-9")])
        XCTAssertEqual(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: nil, in: [older, newer]),
            newer.id
        )
    }

    func testExitedOnlyMatchStillResolves() {
        let exited = makeSession(activity: .exited, artifacts: [
            SessionArtifact(kind: .jiraIssue, label: "PROJ-9")
        ])
        XCTAssertEqual(
            HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: nil, in: [exited]),
            exited.id
        )
    }
}
