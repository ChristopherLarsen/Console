import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class HomeCardLinksTests: XCTestCase {
    private let jiraSite = "https://jira.example.test/browse/PROJ-1"
    private let mr = URL(string: "https://gitlab.example.test/team/app/-/merge_requests/42")!

    private func session(name: String = "Worker", artifacts: [SessionArtifact] = []) -> ConsoleSession {
        ConsoleSession(id: UUID(), claudeSessionID: UUID(), name: name,
                       workingDirectory: URL(fileURLWithPath: "/tmp/links"), terminalView: ConsoleTerminalView(),
                       activity: .idle, attention: .none, summary: nil, artifacts: artifacts, bridgeStatus: .unknown)
    }

    private func authored(_ url: URL, key: String?, title: String = "Change") -> AuthoredMRAttention {
        AuthoredMRAttention(project: "team/app", iid: Int(url.lastPathComponent)!, url: url, title: title,
                            authorUsername: "me", state: "opened", unresolvedDiscussionCount: 1,
                            externalApprovalCount: 0, approvalRulesSatisfied: false, jiraIssueKey: key)
    }

    private func review(_ url: URL, title: String, key: String? = nil) -> MergeRequestSummary {
        MergeRequestSummary(id: url, iidText: url.lastPathComponent, title: title, projectDisplayName: nil,
                            authorDisplayName: nil, isDraft: false, pipelineDisplayState: nil, reviewDisplayState: nil,
                            updatedText: nil, mergeRequestURL: url, sourceOrder: 0, jiraIssueKey: key)
    }

    func testDecisionWithNoSessionUsesTheStoryKeyInItsTitle() {
        let links = HomeCardLinks(authoredItems: [authored(mr, key: "PROJ-9")], configuredJiraURL: jiraSite)
        let decision = OrchestratorPlan.Decision(id: 1, question: "Start it?", options: ["yes"], title: "PROJ-9")
        let result = links.links(for: decision, session: nil)
        XCTAssertEqual(result.jira?.absoluteString, "https://jira.example.test/browse/PROJ-9")
        XCTAssertEqual(result.mergeRequest, mr)
    }

    func testDecisionSessionWithOnlyAStoryFindsItsMergeRequestByKey() {
        let worker = session(name: "PROJ-9 Story", artifacts: [.init(kind: .jiraIssue, label: "PROJ-9")])
        let links = HomeCardLinks(sessions: [worker], authoredItems: [authored(mr, key: "PROJ-9")],
                                  configuredJiraURL: jiraSite)
        let decision = OrchestratorPlan.Decision(id: 2, question: "Push?", options: ["yes"])
        XCTAssertEqual(links.links(for: decision, session: worker).mergeRequest, mr)
    }

    func testBareIIDResolvesOnlyWhenOneKnownMergeRequestHasIt() {
        let other = URL(string: "https://gitlab.example.test/team/other/-/merge_requests/42")!
        let unique = HomeCardLinks(reviewItems: [review(mr, title: "A")])
        XCTAssertEqual(unique.knownMergeRequest(namedIn: "Approve !42?"), mr)
        let ambiguous = HomeCardLinks(reviewItems: [review(mr, title: "A"), review(other, title: "B")])
        XCTAssertNil(ambiguous.knownMergeRequest(namedIn: "Approve !42?"))
        XCTAssertNil(unique.knownMergeRequest(namedIn: "Approve !41?"))
    }

    func testAuthoredMergeRequestFindsItsStoryFromTheTitle() {
        let links = HomeCardLinks(configuredJiraURL: jiraSite)
        XCTAssertEqual(links.jira(forMergeRequest: mr, key: nil, title: "PROJ-9: Fix crash", workKind: .implementation)?
            .absoluteString, "https://jira.example.test/browse/PROJ-9")
        XCTAssertNil(links.jira(forMergeRequest: mr, key: nil, title: "Fix crash", workKind: .implementation))
    }

    func testStoryWithNoKnownMergeRequestHasNone() {
        XCTAssertNil(HomeCardLinks(configuredJiraURL: jiraSite).mergeRequest(forStoryKey: "PROJ-9"))
    }
}
