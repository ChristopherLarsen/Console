import XCTest
@testable import Console

/// Pure launch-flow rules: automatic naming, starter-prompt generation,
/// Jira and GitLab source parsing, remote normalization, and remote matching.
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
            url: URL(string: "https://example.test/browse/ENG-123")
        )
        XCTAssertEqual(SessionPurpose.existingTicket.defaultName(source: source), "ENG-123")
    }

    func testReviewUsesTheMergeRequestIID() {
        let source = SessionLaunchSource.mergeRequest(
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

    // MARK: - New-ticket display names (S-XXXX rule)

    func testNMAKeysRenderAsSNames() {
        XCTAssertEqual(NewTicketSessionNaming.displayName(forJiraKey: "NMA-1234"), "S-1234")
        XCTAssertEqual(NewTicketSessionNaming.displayName(forJiraKey: "NMA-42"), "S-42")
        XCTAssertEqual(NewTicketSessionNaming.displayName(forJiraKey: "nma-7"), "S-7")
    }

    func testNonNMAKeysKeepTheirFullKey() {
        XCTAssertEqual(NewTicketSessionNaming.displayName(forJiraKey: "ENG-1234"), "ENG-1234")
        XCTAssertEqual(NewTicketSessionNaming.displayName(forJiraKey: "ab2-9"), "AB2-9")
    }

    func testStoryNumberParsingAcceptsFriendlyForms() {
        XCTAssertEqual(NewTicketSessionNaming.storyNumber(fromRaw: "1234"), "1234")
        XCTAssertEqual(NewTicketSessionNaming.storyNumber(fromRaw: " 42 "), "42")
        XCTAssertEqual(NewTicketSessionNaming.storyNumber(fromRaw: "S-1234"), "1234")
        XCTAssertEqual(NewTicketSessionNaming.storyNumber(fromRaw: "s7"), "7")
        XCTAssertEqual(NewTicketSessionNaming.storyNumber(fromRaw: "NMA-1234"), "1234")
        XCTAssertEqual(NewTicketSessionNaming.storyNumber(fromRaw: "nma1234"), "1234")
    }

    func testStoryNumberParsingRejectsNonNumbers() {
        XCTAssertNil(NewTicketSessionNaming.storyNumber(fromRaw: ""))
        XCTAssertNil(NewTicketSessionNaming.storyNumber(fromRaw: "ENG-123"))
        XCTAssertNil(NewTicketSessionNaming.storyNumber(fromRaw: "S-12x4"))
        XCTAssertNil(NewTicketSessionNaming.storyNumber(fromRaw: "fix login"))
    }

    func testStoryNumberDisplayNameIsAlwaysTheSForm() {
        XCTAssertEqual(NewTicketSessionNaming.displayName(forStoryNumber: "1234"), "S-1234")
        XCTAssertEqual(NewTicketSessionNaming.displayName(forStoryNumber: "9"), "S-9")
    }

    // MARK: - Starter prompts (never generated)

    private let jiraURL = URL(string: "https://sentinel.example.test/browse/SYN-99999")!
    private let mrURL = URL(string: "https://sentinel.example.test/grp/proj/-/merge_requests/771337")!

    func testNoPurposeGeneratesAStarterPrompt() {
        XCTAssertFalse(SessionPurpose.newTicket.generatesStarterPrompt)
        XCTAssertFalse(SessionPurpose.existingTicket.generatesStarterPrompt)
        XCTAssertFalse(SessionPurpose.review.generatesStarterPrompt)
        XCTAssertFalse(SessionPurpose.general.generatesStarterPrompt)
    }

    func testSourceMetadataIsNeverInterpolatedIntoAPrompt() {
        let jira = SessionLaunchSource.jira(
            key: "SYN-99999",
            title: "SENTINEL-TITLE-ZXCVBNM",
            url: jiraURL
        )
        let mr = SessionLaunchSource.mergeRequest(
            iid: "771337",
            title: "SENTINEL-MR-TITLE-QAZWSX",
            url: mrURL
        )

        for purpose in SessionPurpose.allCases {
            XCTAssertNil(StarterPromptBuilder.prompt(for: purpose, source: jira))
            XCTAssertNil(StarterPromptBuilder.prompt(for: purpose, source: mr))
            XCTAssertNil(StarterPromptBuilder.prompt(for: purpose, source: nil))
        }
    }

    func testLauncherExplainsDeveloperMustEnterWorkContext() {
        XCTAssertTrue(
            StarterPromptBuilder.developerContextNotice.contains("Type work context into the idle session yourself")
        )
        XCTAssertTrue(SessionPurpose.existingTicket.intentDescription.contains("Type the work context yourself"))
        XCTAssertTrue(SessionPurpose.review.intentDescription.contains("Type the review context yourself"))
        XCTAssertFalse(SessionPurpose.existingTicket.intentDescription.lowercased().contains("starter prompt"))
        XCTAssertFalse(SessionPurpose.review.intentDescription.lowercased().contains("starter prompt"))
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
            MergeRequestSourceContext.normalizeRemoteURL("https://GitLab.Example.com/Group/Proj.git"),
            "gitlab.example.com/group/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("git@GitLab.Example.com:Group/Proj.git"),
            "gitlab.example.com/group/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("ssh://git@gitlab.example.com:2222/group/proj.git"),
            "gitlab.example.com/group/proj"
        )
        XCTAssertEqual(
            MergeRequestSourceContext.normalizeRemoteURL("https://gitlab.example.com/group/proj/-/merge_requests/12"),
            "gitlab.example.com/group/proj",
            "MR tails are stripped so MR URLs and remotes share one identity"
        )
    }

    func testRemoteNormalizationRejectsGarbage() {
        XCTAssertNil(MergeRequestSourceContext.normalizeRemoteURL(""))
        XCTAssertNil(MergeRequestSourceContext.normalizeRemoteURL(":://not a remote"))
    }

    // MARK: - Routing identities (hashed association inputs)

    func testRoutingIdentitiesAreOpaqueAndTitleFree() {
        let jira = SessionLaunchSource.jira(key: "eng-123", title: "Secret title", url: jiraURL)
        XCTAssertEqual(jira.routingIdentity, "ENG")

        let mr = SessionLaunchSource.mergeRequest(
            iid: "42",
            title: "Secret MR title",
            url: URL(string: "https://gitlab.com/grp/proj/-/merge_requests/42")!
        )
        XCTAssertEqual(mr.routingIdentity, "gitlab.com/grp/proj")
    }

    // MARK: - Remote matching (real local Git layouts)

    private struct GitFixtureError: Error {}

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=ConsoleFixture",
            "-c", "user.email=fixture@example.test",
        ] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_NAME"] = "ConsoleFixture"
        environment["GIT_AUTHOR_EMAIL"] = "fixture@example.test"
        environment["GIT_COMMITTER_NAME"] = "ConsoleFixture"
        environment["GIT_COMMITTER_EMAIL"] = "fixture@example.test"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError()
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeGitRepo(named name: String, remotes: [String] = []) throws -> SessionWorkspace {
        let directory = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try runGit(["init", "-q"], in: directory)
        for (index, remote) in remotes.enumerated() {
            let remoteName = index == 0 ? "origin" : "origin-\(index)"
            try runGit(["remote", "add", remoteName, remote], in: directory)
        }
        return SessionWorkspace(name: name, directoryPath: directory.path)
    }

    private func posixRelativePath(from originDirectory: URL, to destination: URL) -> String {
        let originParts = originDirectory.resolvingSymlinksInPath().path.split(separator: "/", omittingEmptySubsequences: true)
        let destParts = destination.resolvingSymlinksInPath().path.split(separator: "/", omittingEmptySubsequences: true)
        var shared = 0
        while shared < min(originParts.count, destParts.count), originParts[shared] == destParts[shared] {
            shared += 1
        }
        let ups = Array(repeating: "..", count: originParts.count - shared)
        let downs = destParts[shared...].map(String.init)
        let parts = ups + downs
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    func testUniqueRemoteMatchResolvesToTheSingleWorkspace() async throws {
        let resolver = RepositoryIdentityResolver()
        let alpha = try makeGitRepo(named: "Alpha", remotes: ["https://gitlab.com/grp/proj.git"])
        let beta = try makeGitRepo(named: "Beta", remotes: ["git@gitlab.com:other/thing.git"])

        let outcome = await resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [alpha, beta])

        XCTAssertEqual(outcome, .unique(alpha))
    }

    func testAmbiguousMatchDefersResolution() async throws {
        let resolver = RepositoryIdentityResolver()
        let alpha = try makeGitRepo(named: "Alpha", remotes: ["https://gitlab.com/grp/proj.git"])
        let beta = try makeGitRepo(named: "Beta", remotes: ["git@gitlab.com:grp/proj.git"])

        let outcome = await resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [alpha, beta])

        XCTAssertEqual(outcome, .ambiguous)
    }

    func testSymlinkAliasOfOneCheckoutCountsAsASingleMatch() async throws {
        let resolver = RepositoryIdentityResolver()
        let real = try makeGitRepo(named: "Real", remotes: ["https://gitlab.com/grp/proj.git"])
        let aliasParent = tmpRoot.appendingPathComponent("Alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
        let aliasURL = aliasParent.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: real.directoryURL)
        let alias = SessionWorkspace(name: "RealAlias", directoryPath: aliasURL.path)

        let outcome = await resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [real, alias])

        XCTAssertEqual(outcome, .unique(real), "two path aliases of one physical checkout are one match")
    }

    func testMissingMatchReturnsNone() async throws {
        let resolver = RepositoryIdentityResolver()
        let alpha = try makeGitRepo(named: "Alpha", remotes: ["https://github.com/grp/proj.git"])

        let missing = await resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [alpha])
        let empty = await resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [])
        XCTAssertEqual(missing, .none)
        XCTAssertEqual(empty, .none)
    }

    func testStaleWorkspaceWithoutAccessibleRepositoryIsSkippedByMatching() async {
        let resolver = RepositoryIdentityResolver()
        let stale = SessionWorkspace(name: "Stale", directoryPath: "/nonexistent/\(UUID().uuidString)")

        let outcome = await resolver.match(projectIdentity: "gitlab.com/grp/proj", in: [stale])
        XCTAssertEqual(
            outcome,
            .none,
            "unavailable folders contribute no remotes"
        )
    }

    func testNullDelimitedOutputKeepsOnlyRemoteURLKeys() {
        let output = [
            "remote.origin.url\ngit@host:grp/one.git",
            "remote.upstream.url\nhttps://host/grp/two.git",
            "http.url\nhttps://host/grp/decoy.git",
            "submodule.child.url\nhttps://host/grp/child.git",
            "url.https://host/grp/instead.git.insteadof\ngit@decoy:",
        ].joined(separator: "\0") + "\0"

        XCTAssertEqual(
            RepositoryIdentityResolver.remoteURLs(fromNullDelimitedConfigOutput: output),
            ["git@host:grp/one.git", "https://host/grp/two.git"]
        )
    }

    func testLinkedWorktreeUsesSharedRemotes() async throws {
        let main = tmpRoot.appendingPathComponent("MainCheckout", isDirectory: true)
        try runGit(["init", "-q"], in: main)
        try runGit(["commit", "--allow-empty", "-q", "-m", "init"], in: main)
        try runGit(["remote", "add", "origin", "https://gitlab.example.test/grp/worktree.git"], in: main)
        let linked = tmpRoot.appendingPathComponent("LinkedWorktree", isDirectory: true)
        try runGit(["worktree", "add", "--detach", "-q", linked.path], in: main)

        let linkedWorkspace = SessionWorkspace(name: "Linked", directoryPath: linked.path)
        let mainWorkspace = SessionWorkspace(name: "Main", directoryPath: main.path)
        let other = try makeGitRepo(named: "Other", remotes: ["https://gitlab.example.test/other/thing.git"])
        let resolver = RepositoryIdentityResolver()

        let linkedOutcome = await resolver.match(
            projectIdentity: "gitlab.example.test/grp/worktree",
            in: [linkedWorkspace, other]
        )
        let mainOutcome = await resolver.match(
            projectIdentity: "gitlab.example.test/grp/worktree",
            in: [mainWorkspace, other]
        )
        XCTAssertEqual(linkedOutcome, .unique(linkedWorkspace))
        XCTAssertEqual(mainOutcome, .unique(mainWorkspace))
    }

    func testRelativeGitdirPointerResolvesRemotes() async throws {
        let main = tmpRoot.appendingPathComponent("RelMain", isDirectory: true)
        try runGit(["init", "-q"], in: main)
        try runGit(["commit", "--allow-empty", "-q", "-m", "init"], in: main)
        try runGit(["remote", "add", "origin", "https://gitlab.example.test/grp/relative.git"], in: main)
        let linked = tmpRoot.appendingPathComponent("RelLinked", isDirectory: true)
        try runGit(["worktree", "add", "--detach", "-q", linked.path], in: main)

        let gitdir = URL(
            fileURLWithPath: try runGit(["rev-parse", "--absolute-git-dir"], in: linked)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        )
        let relative = tmpRoot.appendingPathComponent("RelPointer", isDirectory: true)
        try FileManager.default.createDirectory(at: relative, withIntermediateDirectories: true)
        let pointer = "gitdir: \(posixRelativePath(from: relative, to: gitdir))\n"
        try pointer.write(to: relative.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let workspace = SessionWorkspace(name: "Relative", directoryPath: relative.path)
        let resolver = RepositoryIdentityResolver()
        let outcome = await resolver.match(projectIdentity: "gitlab.example.test/grp/relative", in: [workspace])
        XCTAssertEqual(outcome, .unique(workspace))
    }

    func testConfigIncludeContributesRemote() async throws {
        let repo = tmpRoot.appendingPathComponent("IncludedRepo", isDirectory: true)
        try runGit(["init", "-q"], in: repo)
        let included = repo.appendingPathComponent(".git/included.config")
        try """
        [remote "frominclude"]
            url = https://gitlab.example.test/grp/included.git
        """.write(to: included, atomically: true, encoding: .utf8)
        try runGit(["config", "--local", "include.path", "included.config"], in: repo)

        let workspace = SessionWorkspace(name: "Included", directoryPath: repo.path)
        let resolver = RepositoryIdentityResolver()
        let outcome = await resolver.match(projectIdentity: "gitlab.example.test/grp/included", in: [workspace])
        XCTAssertEqual(outcome, .unique(workspace))
    }

    func testNonRemoteURLDoesNotCauseAMatch() async throws {
        let decoy = try makeGitRepo(named: "Decoy")
        try runGit(
            ["config", "--local", "http.url", "https://gitlab.example.test/grp/decoy.git"],
            in: decoy.directoryURL
        )
        try runGit(
            ["config", "--local", "submodule.child.url", "https://gitlab.example.test/grp/decoy.git"],
            in: decoy.directoryURL
        )
        try runGit(
            ["remote", "add", "origin", "https://gitlab.example.test/other/real.git"],
            in: decoy.directoryURL
        )

        let resolver = RepositoryIdentityResolver()
        let decoyOutcome = await resolver.match(projectIdentity: "gitlab.example.test/grp/decoy", in: [decoy])
        let realOutcome = await resolver.match(projectIdentity: "gitlab.example.test/other/real", in: [decoy])
        XCTAssertEqual(decoyOutcome, .none)
        XCTAssertEqual(realOutcome, .unique(decoy))
    }

    func testMissingGitExecutableReturnsNoMatch() async throws {
        let repo = try makeGitRepo(
            named: "HasGitDir",
            remotes: ["https://gitlab.example.test/grp/proj.git"]
        )
        let resolver = RepositoryIdentityResolver(
            gitExecutablePath: tmpRoot.appendingPathComponent("missing-git").path
        )
        let outcome = await resolver.match(projectIdentity: "gitlab.example.test/grp/proj", in: [repo])
        XCTAssertEqual(outcome, .none)
    }

    func testRepoWithoutRemotesAndNonRepoFolderReturnNoMatch() async throws {
        let emptyRepo = try makeGitRepo(named: "EmptyRemotes")
        let plain = tmpRoot.appendingPathComponent("PlainFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let plainWorkspace = SessionWorkspace(name: "Plain", directoryPath: plain.path)
        let resolver = RepositoryIdentityResolver()

        let outcome = await resolver.match(
            projectIdentity: "gitlab.example.test/grp/proj",
            in: [emptyRepo, plainWorkspace]
        )
        XCTAssertEqual(outcome, .none)
    }

    func testSubmoduleCheckoutResolvesItsRemoteAndParentIgnoresSubmoduleURL() async throws {
        let child = tmpRoot.appendingPathComponent("ChildRepo", isDirectory: true)
        try runGit(["init", "-q"], in: child)
        try runGit(["commit", "--allow-empty", "-q", "-m", "child"], in: child)

        let parent = tmpRoot.appendingPathComponent("ParentRepo", isDirectory: true)
        try runGit(["init", "-q"], in: parent)
        try runGit(["commit", "--allow-empty", "-q", "-m", "parent"], in: parent)
        try runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", child.path, "vendor/child"],
            in: parent
        )
        try runGit(["remote", "add", "origin", "https://gitlab.example.test/grp/parent.git"], in: parent)
        let submodule = parent.appendingPathComponent("vendor/child", isDirectory: true)
        try runGit(["remote", "set-url", "origin", "https://gitlab.example.test/grp/child.git"], in: submodule)
        try runGit(
            ["config", "--local", "submodule.vendor/child.url", "https://gitlab.example.test/grp/child.git"],
            in: parent
        )

        let parentWorkspace = SessionWorkspace(name: "Parent", directoryPath: parent.path)
        let submoduleWorkspace = SessionWorkspace(name: "Submodule", directoryPath: submodule.path)
        let resolver = RepositoryIdentityResolver()

        let parentIgnoresChild = await resolver.match(
            projectIdentity: "gitlab.example.test/grp/child",
            in: [parentWorkspace]
        )
        let submoduleMatchesChild = await resolver.match(
            projectIdentity: "gitlab.example.test/grp/child",
            in: [submoduleWorkspace]
        )
        let parentMatchesParent = await resolver.match(
            projectIdentity: "gitlab.example.test/grp/parent",
            in: [parentWorkspace]
        )
        XCTAssertEqual(parentIgnoresChild, .none, "a submodule url on the parent is not a remote")
        XCTAssertEqual(submoduleMatchesChild, .unique(submoduleWorkspace))
        XCTAssertEqual(parentMatchesParent, .unique(parentWorkspace))
    }
}
