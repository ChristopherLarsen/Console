import XCTest
@testable import Console

/// Provider toggle semantics: per-host URL routing, host-tagged launch
/// sources, and neutral merge-request URL parsing across both hosts. All
/// fixture data is invented.
final class CodeHostProviderConfigurationTests: XCTestCase {

    // MARK: - Per-host URL configuration

    private func makeDefaults() -> UserDefaults {
        let suite = "codehost-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEachHostResolvesItsOwnURLs() {
        let defaults = makeDefaults()
        defaults.set("https://gitlab.example.com/reviews", forKey: AppSettings.webViewGitLabReviewsURLKey)
        defaults.set("https://gitlab.example.com/authored", forKey: AppSettings.webViewGitLabMyMergeRequestsURLKey)
        defaults.set("https://github.example.com/review-requested", forKey: AppSettings.webViewGitHubReviewsURLKey)
        defaults.set("https://github.example.com/pulls", forKey: AppSettings.webViewGitHubMyPullRequestsURLKey)

        for provider in CodeHostProvider.allCases {
            XCTAssertEqual(
                CodeHostConfiguration.effectiveURLString(for: .reviewsRequested, provider: provider, defaults: defaults),
                "https://\(provider == .gitlab ? "gitlab" : "github").example.com/\(provider == .gitlab ? "reviews" : "review-requested")"
            )
            XCTAssertEqual(
                CodeHostConfiguration.effectiveURLString(for: .authored, provider: provider, defaults: defaults),
                "https://\(provider == .gitlab ? "gitlab" : "github").example.com/\(provider == .gitlab ? "authored" : "pulls")"
            )
        }
    }

    func testSwitchingProvidersNeverClearsTheOtherHostConfiguration() {
        let defaults = makeDefaults()
        defaults.set("https://gitlab.example.com/reviews", forKey: AppSettings.webViewGitLabReviewsURLKey)

        // Simulate a toggle to GitHub and back; the GitLab value must survive.
        defaults.set("", forKey: AppSettings.webViewGitHubReviewsURLKey)

        XCTAssertEqual(
            CodeHostConfiguration.effectiveURLString(for: .reviewsRequested, provider: .gitlab, defaults: defaults),
            "https://gitlab.example.com/reviews"
        )
        XCTAssertEqual(
            CodeHostConfiguration.effectiveURLString(for: .reviewsRequested, provider: .github, defaults: defaults),
            ""
        )
    }

    func testProviderRawValueRoundTripsAndFallsBackToGitLab() {
        var settings = AppSettings()
        let original = settings.codeHostProviderRaw
        defer { AppSettings().codeHostProviderRaw = original }

        settings.codeHostProvider = .github
        settings = AppSettings()
        XCTAssertEqual(settings.codeHostProvider, .github)

        settings.codeHostProviderRaw = "bogus"
        XCTAssertEqual(settings.codeHostProvider, .gitlab, "Unknown values fall back to GitLab")
    }

    // MARK: - Neutral source parsing

    func testNeutralParserDetectsBothHostShapes() throws {
        let gitlab = try XCTUnwrap(MergeRequestSourceContext.parse(
            from: "https://gitlab.example.com/group/sub/proj/-/merge_requests/42#note_9"
        ))
        XCTAssertEqual(gitlab.host, .gitlab)
        XCTAssertEqual(gitlab.iid, "42")
        XCTAssertEqual(gitlab.projectIdentity, "gitlab.example.com/group/sub/proj")

        let github = try XCTUnwrap(MergeRequestSourceContext.parse(
            from: "https://github.com/acme/console-ios/pull/123"
        ))
        XCTAssertEqual(github.host, .github)
        XCTAssertEqual(github.iid, "123")
        XCTAssertEqual(github.projectIdentity, "github.com/acme/console-ios")
    }

    func testNeutralParserRejectsNonRequestPages() {
        XCTAssertNil(MergeRequestSourceContext.parse(from: "https://github.com/pulls"))
        XCTAssertNil(MergeRequestSourceContext.parse(from: "https://gitlab.com/dashboard"))
        XCTAssertNil(MergeRequestSourceContext.parse(from: "not a url"))
    }

    func testRemoteNormalizationStripsBothRequestTails() {
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("https://github.com/Acme/Proj.git"),
            "github.com/acme/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("git@github.com:Acme/Proj.git"),
            "github.com/acme/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("https://github.com/acme/proj/pull/12"),
            "github.com/acme/proj",
            "PR tails are stripped so PR URLs and remotes share one identity"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("https://gitlab.example.com/group/proj/-/merge_requests/12"),
            "gitlab.example.com/group/proj",
            "MR tails keep collapsing exactly as before the neutral refactor"
        )
    }

    func testLaunchSourceCarriesTheDetectedHost() throws {
        let url = URL(string: "https://github.com/acme/console-ios/pull/7")!
        let source = try XCTUnwrap(
            MergeRequestSourceContext.launchSource(forURL: url, pageTitle: "Add SSO")
        )
        XCTAssertEqual(source, .mergeRequest(host: .github, iid: "7", title: "Add SSO", url: url))
        XCTAssertEqual(source.artifactKind, .githubPullRequest)
        XCTAssertEqual(source.artifactLabel, "PR #7")
    }

    // MARK: - Host-aware naming and artifacts

    func testReviewNamesUseHostConventions() {
        let gitlab = SessionLaunchSource.mergeRequest(
            host: .gitlab, iid: "42", title: nil,
            url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/42")!
        )
        let github = SessionLaunchSource.mergeRequest(
            host: .github, iid: "42", title: nil,
            url: URL(string: "https://github.com/grp/proj/pull/42")!
        )
        XCTAssertEqual(SessionPurpose.review.defaultName(source: gitlab), "Review !42")
        XCTAssertEqual(SessionPurpose.review.defaultName(source: github), "Review #42")
    }

    func testArtifactKindsAreAdditiveAndStable() {
        XCTAssertEqual(SessionArtifactKind(rawValue: "gitlab_merge_request"), .gitlabMergeRequest)
        XCTAssertEqual(SessionArtifactKind(rawValue: "github_pull_request"), .githubPullRequest)
        XCTAssertEqual(SessionArtifactKind.githubPullRequest.rawValue, "github_pull_request")
    }

    func testStarterPromptUsesHostSpecificWording() {
        let prompt = StarterPromptBuilder.prompt(
            for: .review,
            source: .mergeRequest(
                host: .github,
                iid: "9",
                title: "Add tests",
                url: URL(string: "https://github.com/acme/proj/pull/9")!
            )
        )
        XCTAssertTrue(prompt?.hasPrefix("Review GitHub pull request 9: Add tests") ?? false)
    }

    func testRoutingIdentityMatchesTheRemoteForGitHubPRs() {
        let source = SessionLaunchSource.mergeRequest(
            host: .github, iid: "3", title: nil,
            url: URL(string: "https://github.com/Acme/Proj/pull/3")!
        )
        XCTAssertEqual(source.routingIdentity, "github.com/acme/proj")
    }
}
