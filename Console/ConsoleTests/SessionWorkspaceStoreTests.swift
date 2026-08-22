import XCTest
@testable import Console

/// Workspace persistence: add/remove/rename/default behavior, first-workspace
/// defaulting, per-purpose last-used inputs, hashed associations, and the
/// privacy boundary that source metadata never reaches persisted data.
@MainActor
final class SessionWorkspaceStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        suiteName = "SessionWorkspaceStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - Fixtures

    private func makeStore() -> SessionWorkspaceStore {
        SessionWorkspaceStore(defaults: defaults)
    }

    private func makeDirectory(named name: String, gitRemote remote: String? = nil) -> URL {
        let directory = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let remote {
            let gitDir = directory.appendingPathComponent(".git", isDirectory: true)
            try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
            let config = """
            [core]
                repositoryformatversion = 0
            [remote "origin"]
                url = \(remote)

            """
            try? config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    // MARK: - Add / default

    func testFirstAddedWorkspaceBecomesDefaultAutomatically() {
        let store = makeStore()
        let added = store.add(name: "Alpha", directoryURL: makeDirectory(named: "Alpha"))

        XCTAssertEqual(store.workspaces.map(\.name), ["Alpha"])
        XCTAssertEqual(store.defaultWorkspaceID, added.id)
    }

    func testLaterAddsDoNotStealTheDefault() {
        let store = makeStore()
        let first = store.add(name: "One", directoryURL: makeDirectory(named: "One"))
        let second = store.add(name: "Two", directoryURL: makeDirectory(named: "Two"))

        XCTAssertEqual(store.defaultWorkspaceID, first.id)
        XCTAssertNotEqual(second.id, first.id)
    }

    func testAddingSameFolderTwiceReturnsExistingEntry() {
        let store = makeStore()
        let directory = makeDirectory(named: "Dup")
        _ = store.add(name: directory.lastPathComponent, directoryURL: directory)
        let again = store.add(name: "Renamed", directoryURL: directory)

        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(again.name, "Dup", "the saved entry is returned unchanged")
    }

    func testDuplicateWorkspaceNamesAreSuffixed() {
        let store = makeStore()
        _ = store.add(name: "Repo", directoryURL: makeDirectory(named: "RepoA"))
        _ = store.add(name: "Repo", directoryURL: makeDirectory(named: "RepoB"))

        XCTAssertEqual(store.workspaces.map(\.name), ["Repo", "Repo 2"])
    }

    // MARK: - Rename / remove / set default

    func testRenameUpdatesOnlyTheName() throws {
        let store = makeStore()
        let workspace = store.add(name: "Before", directoryURL: makeDirectory(named: "Before"))

        store.rename(id: workspace.id, to: "  After  ")

        XCTAssertEqual(store.workspaces.first?.name, "After")
        XCTAssertEqual(store.workspaces.first?.directoryPath, workspace.directoryPath)
    }

    func testEmptyRenameIsIgnored() {
        let store = makeStore()
        let workspace = store.add(name: "Keep", directoryURL: makeDirectory(named: "Keep"))

        store.rename(id: workspace.id, to: "   ")

        XCTAssertEqual(store.workspaces.first?.name, "Keep")
    }

    func testRemoveDropsWorkspaceAndEverythingLearnedAboutIt() {
        let store = makeStore()
        let kept = store.add(name: "Kept", directoryURL: makeDirectory(named: "Kept"))
        let removed = store.add(name: "Gone", directoryURL: makeDirectory(named: "Gone"))
        store.setDefault(id: removed.id)
        store.noteUse(workspaceID: removed.id, purpose: .existingTicket)
        store.rememberAssociation(routingIdentity: "ENG", workspaceID: removed.id)

        store.remove(id: removed.id)

        XCTAssertEqual(store.workspaces.map(\.id), [kept.id])
        XCTAssertNil(store.defaultWorkspaceID)
        XCTAssertNil(store.lastUsedWorkspaceID(for: .existingTicket))
        XCTAssertNil(store.associatedWorkspaceID(forRoutingIdentity: "ENG"))
    }

    func testSetDefaultToUnknownClearsIt() {
        let store = makeStore()
        let workspace = store.add(name: "Solo", directoryURL: makeDirectory(named: "Solo"))

        store.setDefault(id: workspace.id)
        XCTAssertEqual(store.defaultWorkspaceID, workspace.id)

        store.setDefault(id: UUID())
        XCTAssertNil(store.defaultWorkspaceID)
    }

    // MARK: - Availability and requirements

    func testRemovedFolderIsUnavailableAndIgnoredDuringResolution() {
        let store = makeStore()
        let directory = makeDirectory(named: "Vanishing")
        _ = store.add(name: "Vanishing", directoryURL: directory)
        XCTAssertTrue(store.isAvailable(store.workspaces[0]))

        try? FileManager.default.removeItem(at: directory)

        XCTAssertFalse(store.isAvailable(store.workspaces[0]))
        XCTAssertTrue(store.availableWorkspaces.isEmpty)
        XCTAssertTrue(store.resolvableWorkspaces(purpose: .general).isEmpty)
        // The entry is recoverable rather than silently dropped.
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testReviewPurposeRequiresGitRepositoryOthersDoNot() {
        let store = makeStore()
        _ = store.add(name: "Plain", directoryURL: makeDirectory(named: "Plain"))
        _ = store.add(name: "Gitly", directoryURL: makeDirectory(named: "Gitly", gitRemote: "https://gitlab.com/grp/proj.git"))

        XCTAssertEqual(Set(store.resolvableWorkspaces(purpose: .review).map(\.name)), ["Gitly"])
        XCTAssertEqual(Set(store.resolvableWorkspaces(purpose: .general).map(\.name)), ["Plain", "Gitly"])
    }

    // MARK: - Last used per purpose

    func testLastUsedTrackedIndependentlyPerPurpose() {
        let store = makeStore()
        let newTicketHome = store.add(name: "New", directoryURL: makeDirectory(named: "New"))
        let reviewHome = store.add(name: "Rev", directoryURL: makeDirectory(named: "Rev"))

        store.noteUse(workspaceID: newTicketHome.id, purpose: .newTicket)
        store.noteUse(workspaceID: reviewHome.id, purpose: .review)

        XCTAssertEqual(store.lastUsedWorkspaceID(for: .newTicket), newTicketHome.id)
        XCTAssertEqual(store.lastUsedWorkspaceID(for: .review), reviewHome.id)
        XCTAssertNil(store.lastUsedWorkspaceID(for: .general))
    }

    // MARK: - Hashed associations

    func testAssociationRoundTripUsesRoutingIdentity() {
        let store = makeStore()
        let workspace = store.add(name: "Eng", directoryURL: makeDirectory(named: "Eng"))

        store.rememberAssociation(routingIdentity: "ENG", workspaceID: workspace.id)

        XCTAssertEqual(store.associatedWorkspaceID(forRoutingIdentity: "ENG"), workspace.id)
        XCTAssertNil(store.associatedWorkspaceID(forRoutingIdentity: "OTHER"))
        XCTAssertEqual(store.associationCount, 1)
    }

    func testAssociationSurvivesReloadThroughUserDefaults() {
        let identity = GitLabSourceParsingFixture.mrProjectIdentity
        let store = makeStore()
        let workspace = store.add(name: "MR", directoryURL: makeDirectory(named: "MR", gitRemote: "https://gitlab.com/grp/proj.git"))
        store.rememberAssociation(routingIdentity: identity, workspaceID: workspace.id)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.workspaces.map(\.id), [workspace.id])
        XCTAssertEqual(reloaded.defaultWorkspaceID, workspace.id)
        XCTAssertEqual(reloaded.associatedWorkspaceID(forRoutingIdentity: identity), workspace.id)
        XCTAssertEqual(reloaded.lastUsedWorkspaceID(for: .review), nil)
    }

    func testClearAssociationsRemovesRoutingButKeepsWorkspacesDefaultsAndLastUsed() {
        let store = makeStore()
        let workspace = store.add(name: "W", directoryURL: makeDirectory(named: "W"))
        store.setDefault(id: workspace.id)
        store.noteUse(workspaceID: workspace.id, purpose: .general)
        store.rememberAssociation(routingIdentity: "ENG", workspaceID: workspace.id)

        store.clearLearnedAssociations()

        XCTAssertEqual(store.associationCount, 0)
        XCTAssertNil(store.associatedWorkspaceID(forRoutingIdentity: "ENG"))
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.defaultWorkspaceID, workspace.id)
        XCTAssertEqual(store.lastUsedWorkspaceID(for: .general), workspace.id)
    }

    /// Privacy: persisted association data contains only 64-char hex hashes
    /// mapped to UUID strings — never the raw project key or any URL.
    func testPersistedAssociationsContainOnlyHashesAndIDs() throws {
        let store = makeStore()
        let workspace = store.add(name: "Secretless", directoryURL: makeDirectory(named: "Secretless"))
        store.rememberAssociation(routingIdentity: "ENG", workspaceID: workspace.id)
        store.rememberAssociation(
            routingIdentity: "gitlab.com/grp/proj",
            workspaceID: workspace.id
        )

        let raw = try XCTUnwrap(defaults.object(forKey: "sessionWorkspaces.associations") as? [String: String])
        XCTAssertEqual(raw.count, 2)
        for (key, value) in raw {
            XCTAssertTrue(key.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil, "key must be a SHA-256 hex digest")
            XCTAssertNotNil(UUID(uuidString: value), "value must be a workspace UUID")
        }
        XCTAssertFalse(raw.keys.contains("ENG"))
        XCTAssertFalse(raw.values.contains("ENG"))

        let allPayload = String(data: defaults.dictionaryRepresentation().description.data(using: .utf8)!, encoding: .utf8)!
        XCTAssertFalse(allPayload.contains("jira-project:"), "raw routing identities are never stored")
    }

    func testRoutingHashMatchesSHA256AndIsStable() {
        // Well-known SHA-256("abc").
        XCTAssertEqual(
            SessionWorkspaceStore.routingHash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(SessionWorkspaceStore.routingHash("abc"), SessionWorkspaceStore.routingHash("abc"))
        XCTAssertNotEqual(SessionWorkspaceStore.routingHash("abc"), SessionWorkspaceStore.routingHash("abd"))
    }

    // MARK: - Containment

    func testContainsChecksPathContainmentForSelectedSessionResolution() {
        let root = makeDirectory(named: "Monorepo")
        let nested = root.appendingPathComponent("Sub", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let workspace = SessionWorkspace(name: "Monorepo", directoryPath: root.path)

        XCTAssertTrue(SessionWorkspaceStore.contains(workspace, directory: nested))
        XCTAssertTrue(SessionWorkspaceStore.contains(workspace, directory: root))
        XCTAssertFalse(SessionWorkspaceStore.contains(workspace, directory: tmpRoot))
    }
}

private enum GitLabSourceParsingFixture {
    static let mrProjectIdentity = "gitlab.com/grp/proj"
}
