import XCTest
@testable import Console

/// Start Review input resolution: URL, `!IID` / bare number, and Jira key
/// against the shared scan's open merge requests.
final class ReviewLaunchResolverTests: XCTestCase {

    private func item(
        iid: String?,
        title: String,
        jiraIssueKey: String? = nil,
        order: Int = 0,
        project: String = "group/project"
    ) -> MergeRequestSummary {
        let url = URL(string: "https://gitlab.example.test/\(project)/-/merge_requests/\(iid ?? "0")")!
        return MergeRequestSummary(
            id: url,
            iidText: iid,
            title: title,
            projectDisplayName: "Project",
            authorDisplayName: nil,
            isDraft: false,
            pipelineDisplayState: nil,
            reviewDisplayState: nil,
            updatedText: nil,
            mergeRequestURL: url,
            sourceOrder: order,
            jiraIssueKey: jiraIssueKey
        )
    }

    func testResolvesMergeRequestURLAgainstCandidates() throws {
        let candidate = item(iid: "42", title: "NMA-1234: fix login", order: 0)
        let target = try XCTUnwrap(ReviewLaunchResolver.resolve(
            raw: "https://gitlab.example.test/group/project/-/merge_requests/42",
            candidates: [candidate]
        ))
        XCTAssertEqual(target.iid, "42")
        XCTAssertEqual(target.title, "NMA-1234: fix login")
        XCTAssertEqual(target.jiraIssueKey, "NMA-1234")
    }

    func testResolvesBangNumber() throws {
        let candidate = item(iid: "42", title: "Fix login", jiraIssueKey: "NMA-9", order: 0)
        let target = try XCTUnwrap(ReviewLaunchResolver.resolve(raw: "!42", candidates: [candidate]))
        XCTAssertEqual(target.iid, "42")
        XCTAssertEqual(target.url, candidate.mergeRequestURL)
        XCTAssertEqual(target.jiraIssueKey, "NMA-9")
    }

    func testResolvesBareNumber() throws {
        let candidate = item(iid: "7", title: "Fix login", order: 0)
        let target = try XCTUnwrap(ReviewLaunchResolver.resolve(raw: "7", candidates: [candidate]))
        XCTAssertEqual(target.iid, "7")
    }

    func testResolvesJiraKeyFromTitle() throws {
        let candidate = item(iid: "5", title: "NMA-1234: fix login", order: 0)
        let target = try XCTUnwrap(ReviewLaunchResolver.resolve(raw: "NMA-1234", candidates: [candidate]))
        XCTAssertEqual(target.iid, "5")
        XCTAssertEqual(target.jiraIssueKey, "NMA-1234")
    }

    func testResolvesJiraKeyFromReportedField() throws {
        let candidate = item(iid: "6", title: "unrelated title", jiraIssueKey: "nma-77", order: 0)
        let target = try XCTUnwrap(ReviewLaunchResolver.resolve(raw: "NMA-77", candidates: [candidate]))
        XCTAssertEqual(target.iid, "6")
        XCTAssertEqual(target.jiraIssueKey, "nma-77")
    }

    func testUnknownInputsResolveToNil() {
        let candidates = [item(iid: "42", title: "Fix login", order: 0)]
        XCTAssertNil(ReviewLaunchResolver.resolve(raw: "!99", candidates: candidates))
        XCTAssertNil(ReviewLaunchResolver.resolve(raw: "NMA-404", candidates: candidates))
        XCTAssertNil(ReviewLaunchResolver.resolve(raw: "not a source", candidates: candidates))
        XCTAssertNil(ReviewLaunchResolver.resolve(raw: "", candidates: candidates))
    }

    func testTargetRequiresReportedNumber() {
        XCTAssertNil(ReviewLaunchResolver.target(for: item(iid: nil, title: "Fix login")))
    }
}
