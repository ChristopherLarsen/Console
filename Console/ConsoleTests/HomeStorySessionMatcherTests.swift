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
