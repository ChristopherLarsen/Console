import XCTest
@testable import Console

/// GitLab URL routing, merge-request URL parsing, remote normalization, and
/// launch-source naming. All fixture data is invented.
final class CodeHostConfigurationTests: XCTestCase {

    // MARK: - URL configuration

    private func makeDefaults() -> UserDefaults {
        let suite = "codehost-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEachListResolvesItsOwnURL() {
        let defaults = makeDefaults()
        defaults.set("https://gitlab.example.com/reviews", forKey: AppSettings.webViewGitLabReviewsURLKey)
        defaults.set("https://gitlab.example.com/authored", forKey: AppSettings.webViewGitLabMyMergeRequestsURLKey)

        XCTAssertEqual(
            CodeHostConfiguration.effectiveURLString(for: .reviewsRequested, defaults: defaults),
            "https://gitlab.example.com/reviews"
        )
        XCTAssertEqual(
            CodeHostConfiguration.effectiveURLString(for: .authored, defaults: defaults),
            "https://gitlab.example.com/authored"
        )
    }

    func testUnconfiguredListsResolveToEmptyStrings() {
        let defaults = makeDefaults()
        XCTAssertEqual(CodeHostConfiguration.effectiveURLString(for: .reviewsRequested, defaults: defaults), "")
        XCTAssertEqual(CodeHostConfiguration.effectiveURLString(for: .authored, defaults: defaults), "")
    }

    // MARK: - Source parsing

    func testParserDetectsMergeRequestShape() throws {
        let gitlab = try XCTUnwrap(MergeRequestSourceContext.parse(
            from: "https://gitlab.example.com/group/sub/proj/-/merge_requests/42#note_9"
        ))
        XCTAssertEqual(gitlab.iid, "42")
        XCTAssertEqual(gitlab.projectIdentity, "gitlab.example.com/group/sub/proj")
    }

    func testParserRejectsNonRequestPages() {
        XCTAssertNil(MergeRequestSourceContext.parse(from: "https://gitlab.com/dashboard"))
        XCTAssertNil(MergeRequestSourceContext.parse(from: "not a url"))
    }

    func testRemoteNormalizationStripsRequestTails() {
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("https://gitlab.example.com/Acme/Proj.git"),
            "gitlab.example.com/acme/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("git@gitlab.example.com:Acme/Proj.git"),
            "gitlab.example.com/acme/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("ssh://git@gitlab.example.com/acme/proj.git"),
            "gitlab.example.com/acme/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("https://gitlab.example.com/group/proj/-/merge_requests/12"),
            "gitlab.example.com/group/proj",
            "MR tails collapse onto the project identity"
        )
    }

    func testLaunchSourceCarriesTheMergeRequestIdentity() throws {
        let url = URL(string: "https://gitlab.example.com/group/proj/-/merge_requests/7")!
        let source = try XCTUnwrap(
            MergeRequestSourceContext.launchSource(forURL: url, pageTitle: "Add SSO")
        )
        XCTAssertEqual(source, .mergeRequest(iid: "7", title: "Add SSO", url: url))
        XCTAssertEqual(source.artifactKind, .gitlabMergeRequest)
        XCTAssertEqual(source.artifactLabel, "MR !7")
    }

    // MARK: - Naming and artifacts

    func testReviewNamesUseMRConventions() {
        let source = SessionLaunchSource.mergeRequest(
            iid: "42", title: nil,
            url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/42")!
        )
        XCTAssertEqual(SessionPurpose.review.defaultName(source: source), "Review !42")
    }

    func testArtifactKindRawValuesAreStable() {
        XCTAssertEqual(SessionArtifactKind(rawValue: "gitlab_merge_request"), .gitlabMergeRequest)
        XCTAssertNil(SessionArtifactKind(rawValue: "github_pull_request"), "GitHub artifact support is removed")
    }

    func testStarterPromptNeverIncludesMergeRequestMetadata() {
        let prompt = StarterPromptBuilder.prompt(
            for: .review,
            source: .mergeRequest(
                iid: "9",
                title: "Add tests",
                url: URL(string: "https://example.test/acme/proj/-/merge_requests/9")!
            )
        )
        XCTAssertNil(prompt)
    }

    func testRoutingIdentityMatchesTheRemote() {
        let source = SessionLaunchSource.mergeRequest(
            iid: "3", title: nil,
            url: URL(string: "https://GitLab.example.com/Acme/Proj/-/merge_requests/3")!
        )
        XCTAssertEqual(source.routingIdentity, "gitlab.example.com/acme/proj")
    }
}
