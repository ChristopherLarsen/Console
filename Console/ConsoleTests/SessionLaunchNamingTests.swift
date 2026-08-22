import XCTest
@testable import Console

/// Pure launch-flow rules: automatic naming, starter-prompt generation,
/// Jira/GitLab source parsing, remote normalization, and remote matching.
@MainActor
final class SessionLaunchNamingTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("naming-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - Automatic naming

    func testAutomaticNamesForCleanPurposes() {
        XCTAssertEqual(SessionPurpose.newTicket.defaultName(source: nil), "New Ticket")
        XCTAssertEqual(SessionPurpose.general.defaultName(source: nil), "General")
    }

    func testExistingTicketUsesTheJiraKey() {
        let source = SessionLaunchSource.jira(
            key: "ENG-123",
            title: "Fix login",
            url: URL(string: "https://acme.atlassian.net/browse/ENG-123")
        )
        XCTAssertEqual(SessionPurpose.existingTicket.defaultName(source: source), "ENG-123")
    }

    func testReviewUsesTheMergeRequestIID() {
        let source = SessionLaunchSource.gitLabMergeRequest(
            iid: "42",
            title: nil,
            url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/42")!
        )
        XCTAssertEqual(SessionPurpose.review.defaultName(source: source), "Review !42")
    }

    func testDuplicateNamesStillSuffixThroughTheStore() {
        XCTAssertEqual(SessionStore.uniquedName("Review !42", existingNames: []), "Review !42")
        XCTAssertEqual(SessionStore.uniquedName("Review !42", existingNames: ["Review !42"]), "Review !42 2")
        XCTAssertEqual(
            SessionStore.uniquedName("General", existingNames: ["General", "General 2", "General 3"]),
            "General 4"
        )
    }

    // MARK: - Starter prompts

    private let jiraURL = URL(string: "https://acme.atlassian.net/browse/ENG-123")!
    private let mrURL = URL(string: "https://gitlab.com/grp/proj/-/merge_requests/42")!

    func testJiraPromptIncludesOnlyKeyTitleAndURL() {
        let prompt = StarterPromptBuilder.prompt(
            for: .existingTicket,
            source: .jira(key: "ENG-123", title: "Fix login", url: jiraURL)
        )

        XCTAssertEqual(
            prompt,
            """
            Work on Jira ticket ENG-123: Fix login
            Source: https://acme.atlassian.net/browse/ENG-123

            Inspect the repository and the ticket context available to you, then begin the work. If critical ticket details are unavailable, ask me before making assumptions.
            """
        )
    }

    func testJiraPromptOmitsMissingTitleAndURLLines() {
        XCTAssertEqual(
            StarterPromptBuilder.prompt(for: .existingTicket, source: .jira(key: "ENG-9", title: nil, url: nil)),
            """
            Work on Jira ticket ENG-9

            Inspect the repository and the ticket context available to you, then begin the work. If critical ticket details are unavailable, ask me before making assumptions.
            """
        )
        XCTAssertFalse(
            StarterPromptBuilder.prompt(for: .existingTicket, source: .jira(key: "ENG-9", title: "", url: jiraURL))!
                .contains(": \n"),
            "empty titles are omitted rather than placeholdered"
        )
    }

    func testReviewPromptIncludesOnlyIIDTitleAndURL() {
        let prompt = StarterPromptBuilder.prompt(
            for: .review,
            source: .gitLabMergeRequest(iid: "42", title: "Add SSO", url: mrURL)
        )

        XCTAssertEqual(
            prompt,
            """
            Review GitLab merge request 42: Add SSO
            Source: https://gitlab.com/grp/proj/-/merge_requests/42

            Inspect the merge-request diff and report concrete findings prioritized by severity, including regressions, security issues, and missing tests. Do not modify files unless I ask.
            """
        )
    }

    func testNewTicketAndGeneralCreateNoStarterPrompt() {
        let jiraSource = SessionLaunchSource.jira(key: "ENG-1", title: "T", url: jiraURL)
        XCTAssertNil(StarterPromptBuilder.prompt(for: .newTicket, source: jiraSource))
        XCTAssertNil(StarterPromptBuilder.prompt(for: .general, source: jiraSource))
        XCTAssertNil(StarterPromptBuilder.prompt(for: .newTicket, source: nil))
        XCTAssertNil(StarterPromptBuilder.prompt(for: .general, source: nil))
    }

    // MARK: - Jira parsing

    func testJiraKeyParsingFromBareKeysAndURLs() {
        XCTAssertEqual(JiraSourceContext.parseKey(from: "eng-123"), "ENG-123")
        XCTAssertEqual(JiraSourceContext.parseKey(from: "https://acme.atlassian.net/browse/ENG-123"), "ENG-123")
        XCTAssertEqual(JiraSourceContext.parseKey(from: "https://acme.atlassian.net/jira/software/c/projects/ENG/issues/ENG-123?selectedIssue=ENG-123"), "ENG-123")
        XCTAssertEqual(JiraSourceContext.parseIssueKey(fromURL: URL(string: "https://x.com/browse/AB2-7?utm=1")!), "AB2-7")
    }

    func testJiraParsingRejectsNonIssueInputs() {
        XCTAssertNil(JiraSourceContext.parseKey(from: ""))
        XCTAssertNil(JiraSourceContext.parseKey(from: "https://acme.atlassian.net/browse/"))
        XCTAssertNil(JiraSourceContext.parseIssueKey(fromURL: URL(string: "https://acme.atlassian.net/dashboard")!))
        XCTAssertNil(JiraSourceContext.projectKeyPrefix(of: "NOTAKEY"))
    }

    func testProjectPrefixIsUppercasedBeforeTheDash() {
        XCTAssertEqual(JiraSourceContext.projectKeyPrefix(of: "eng-123"), "ENG")
        XCTAssertEqual(JiraSourceContext.projectKeyPrefix(of: "Ab2-9"), "AB2")
    }

    // MARK: - GitLab parsing and normalization

    func testMergeRequestParsingExtractsIIDAndProject() {
        let info = GitLabSourceContext.parseMergeRequest(
            from: "https://gitlab.example.com/group/sub/proj/-/merge_requests/42#note_9"
        )

        XCTAssertEqual(info?.iid, "42")
        XCTAssertEqual(info?.projectURL.absoluteString, "https://gitlab.example.com/group/sub/proj")
        XCTAssertEqual(info?.projectIdentity, "gitlab.example.com/group/sub/proj")
    }

    func testProjectIdentityFromMergeRequestURLOrNil() {
        let url = URL(string: "https://gitlab.com/grp/proj/-/merge_requests/7")!
        XCTAssertEqual(GitLabSourceContext.projectIdentity(fromMergeRequestURL: url), "gitlab.com/grp/proj")

        let plain = URL(string: "https://gitlab.com/dashboard")!
        XCTAssertNil(GitLabSourceContext.projectIdentity(fromMergeRequestURL: plain))
    }

    func testRemoteNormalizationCollapsesHTTPSAndSSHForms() {
        XCTAssertEqual(
            GitLabSourceContext.normalizeRemoteURL("https://GitLab.Example.com/Group/Proj.git"),
            "gitlab.example.com/group/proj"
        )
        XCTAssertEqual(
            GitLabSourceContext.normalizeRemoteURL("git@GitLab.Example.com:Group/Proj.git"),
            "gitlab.example.com/group/proj"
        )
        XCTAssertEqual(
            GitLabSourceContext.normalizeRemoteURL("ssh://git@gitlab.example.com:2222/group/proj.git"),
            "gitlab.example.com/group/proj"
        )
        XCTAssertEqual(
            GitLabSourceContext.normalizeRemoteURL("https://gitlab.example.com/group/proj/-/merge_requests/12"),
            "gitlab.example.com/group/proj",
            "MR tails are stripped so MR URLs and remotes share one identity"
        )
    }

    func testRemoteNormalizationRejectsGarbage() {
        XCTAssertNil(GitLabSourceContext.normalizeRemoteURL(""))
        XCTAssertNil(GitLabSourceContext.normalizeRemoteURL(":://not a remote"))
    }

    // MARK: - Routing identities (hashed association inputs)

    func testRoutingIdentitiesAreOpaqueAndTitleFree() {
        let jira = SessionLaunchSource.jira(key: "eng-123", title: "Secret title", url: jiraURL)
        XCTAssertEqual(jira.routingIdentity, "ENG")

        let mr = SessionLaunchSource.gitLabMergeRequest(iid: "42", title: "Secret MR title", url: mrURL)
        XCTAssertEqual(mr.routingIdentity, "gitlab.com/grp/proj")
    }

    // MARK: - Remote matching

    private func makeRepo(named name: String, remotes: [String]) -> SessionWorkspace {
        let directory = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gitDir = directory.appendingPathComponent(".git", isDirectory: true)
        try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        var config = "[core]\n    repositoryformatversion = 0\n"
        for (index, remote) in remotes.enumerated() {
            config += "\n[remote \"origin\(index == 0 ? "" : "-\(index)")\"]\n    url = \(remote)\n"
        }
        try? config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return SessionWorkspace(name: name, directoryPath: directory.path)
    }

    func testUniqueRemoteMatchResolvesToTheSingleWorkspace() {
        let resolver = RepositoryIdentityResolver()
        let alpha = makeRepo(named: "Alpha", remotes: ["https://gitlab.com/grp/proj.git"])
        let beta = makeRepo(named: "Beta", remotes: ["git@gitlab.com:other/thing.git"])

        let outcome = resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [alpha, beta])

        XCTAssertEqual(outcome, .unique(alpha))
    }

    func testAmbiguousMatchDefersResolution() {
        let resolver = RepositoryIdentityResolver()
        let alpha = makeRepo(named: "Alpha", remotes: ["https://gitlab.com/grp/proj.git"])
        let beta = makeRepo(named: "Beta", remotes: ["git@gitlab.com:grp/proj.git"])

        let outcome = resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [alpha, beta])

        XCTAssertEqual(outcome, .ambiguous)
    }

    func testMissingMatchReturnsNone() {
        let resolver = RepositoryIdentityResolver()
        let alpha = makeRepo(named: "Alpha", remotes: ["https://github.com/grp/proj.git"])

        XCTAssertEqual(resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [alpha]), .none)
        XCTAssertEqual(resolver.match(projectIdentity: "gitlab.com/grp/proj", in: []), .none)
    }

    func testStaleWorkspaceWithoutAccessibleRepositoryIsSkippedByMatching() {
        let resolver = RepositoryIdentityResolver()
        let stale = SessionWorkspace(name: "Stale", directoryPath: "/nonexistent/\(UUID().uuidString)")

        XCTAssertEqual(
            resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [stale]),
            .none,
            "unavailable folders contribute no remotes"
        )
    }

    func testRemoteConfigParserReadsAllRemoteSections() {
        let config = """
        [core]
            bare = false
        [remote "origin"]
            url = git@host:grp/one.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
            url = https://host/grp/two.git
        """
        XCTAssertEqual(
            RepositoryIdentityResolver.remoteURLs(inConfig: config),
            ["git@host:grp/one.git", "https://host/grp/two.git"]
        )
    }
}
