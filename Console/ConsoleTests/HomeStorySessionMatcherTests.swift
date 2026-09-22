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
        name: String? = nil,
        artifacts: [SessionArtifact]
    ) -> ConsoleSession {
        counter += 1
        return ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: name ?? "S\(counter)",
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

    func testCatalogMatchingUsesDurableIdentityRoleAndSiteInsteadOfChipLabels() throws {
        let catalog = SessionAssociationStore(url: nil)
        let author = makeSession(artifacts: [])
        let reviewer = makeSession(artifacts: [])
        let artifacts: [SessionArtifact] = [.init(kind: .jiraIssue, label: "Renamed story", url: issueURL)]
        try catalog.remember(record: .init(claudeSessionID: author.claudeSessionID, name: "Author",
            workingDirectory: author.workingDirectory, purpose: .existingTicket), artifacts: artifacts)
        try catalog.remember(record: .init(claudeSessionID: reviewer.claudeSessionID, name: "Reviewer",
            workingDirectory: reviewer.workingDirectory, purpose: .review), artifacts: artifacts)
        XCTAssertEqual(HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: issueURL,
            in: [author, reviewer], associations: catalog), author.id)
        XCTAssertNil(HomeStorySessionMatcher.sessionID(for: "PROJ-9", issueURL: URL(string: "https://other.test/browse/PROJ-9"),
            in: [author, reviewer], associations: catalog))
    }

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

    func testJiraNavigationMapsNewTicketDisplayNameToNMAKey() {
        let session = makeSession(name: "S-1234", artifacts: [])
        XCTAssertEqual(HomeStorySessionMatcher.jiraURL(for: session,
            configuredURL: "https://jira.example.test")?.absoluteString,
            "https://jira.example.test/browse/NMA-1234")
    }

    func testJiraNavigationMapsNewTicketArtifactLabelToNMAKey() {
        let session = makeSession(artifacts: [.init(kind: .jiraIssue, label: "S-1234")])
        XCTAssertEqual(HomeStorySessionMatcher.jiraURL(for: session,
            configuredURL: "https://jira.example.test")?.absoluteString,
            "https://jira.example.test/browse/NMA-1234")
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

    // MARK: - Review continuation resolution

    private let reviewURL = URL(string: "https://gitlab.example.test/team/app/-/merge_requests/42")!

    private func reviewSession(activity: SessionActivity, name: String? = nil) -> ConsoleSession {
        var session = makeSession(
            activity: activity,
            name: name,
            artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42", url: reviewURL)]
        )
        session.purpose = .review
        return session
    }

    func testReviewResolutionPrefersTheLiveSession() {
        let live = reviewSession(activity: .working)
        let exited = reviewSession(activity: .exited)
        XCTAssertEqual(
            HomeStorySessionMatcher.reviewResolution(for: reviewURL, in: [exited, live]),
            .live(live.id)
        )
    }

    func testReviewResolutionResumesAnExitedSessionWithoutACatalog() {
        let exited = reviewSession(activity: .exited, name: "NMA-9 Review")
        let resolution = HomeStorySessionMatcher.reviewResolution(for: reviewURL, in: [exited])
        guard case let .resumable(record) = resolution else {
            return XCTFail("expected resumable, got \(resolution)")
        }
        XCTAssertEqual(record.claudeSessionID, exited.claudeSessionID)
        XCTAssertEqual(record.name, "NMA-9 Review")
    }

    func testReviewResolutionResumesACatalogConversationNotInTheList() throws {
        let catalog = SessionAssociationStore(url: nil)
        let id = UUID()
        try catalog.remember(record: .init(claudeSessionID: id, name: "NMA-9 Review",
            workingDirectory: URL(fileURLWithPath: "/tmp/review"), purpose: .review),
            artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42", url: reviewURL)])

        let resolution = HomeStorySessionMatcher.reviewResolution(for: reviewURL, in: [], associations: catalog)
        guard case let .resumable(record) = resolution else {
            return XCTFail("expected resumable, got \(resolution)")
        }
        XCTAssertEqual(record.claudeSessionID, id)
    }

    func testReviewResolutionSkipsSelfReviewConversations() throws {
        let catalog = SessionAssociationStore(url: nil)
        try catalog.remember(record: .init(claudeSessionID: UUID(), name: "MR-42 Self Review",
            workingDirectory: URL(fileURLWithPath: "/tmp/self"), purpose: .review),
            artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42", url: reviewURL)])

        XCTAssertEqual(
            HomeStorySessionMatcher.reviewResolution(for: reviewURL, in: [], associations: catalog),
            .none
        )
    }

    func testReviewResolutionChoosesTheNewestWhenAmbiguous() throws {
        let catalog = SessionAssociationStore(url: nil)
        let older = UUID()
        let newer = UUID()
        try catalog.remember(record: .init(claudeSessionID: older, name: "Older Review",
            workingDirectory: URL(fileURLWithPath: "/tmp/older"), purpose: .review),
            artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42", url: reviewURL)])
        Thread.sleep(forTimeInterval: 0.02)
        try catalog.remember(record: .init(claudeSessionID: newer, name: "Newer Review",
            workingDirectory: URL(fileURLWithPath: "/tmp/newer"), purpose: .review),
            artifacts: [.init(kind: .gitlabMergeRequest, label: "MR !42", url: reviewURL)])

        let resolution = HomeStorySessionMatcher.reviewResolution(for: reviewURL, in: [], associations: catalog)
        guard case let .resumable(record) = resolution else {
            return XCTFail("expected resumable, got \(resolution)")
        }
        XCTAssertEqual(record.claudeSessionID, newer)
    }

    func testReviewResolutionNoneWithoutAnyPriorSession() {
        XCTAssertEqual(HomeStorySessionMatcher.reviewResolution(for: reviewURL, in: []), .none)
    }
}
