import XCTest
@testable import Console

/// Single Session Folder store: set/clear, stable identity, availability,
/// git requirement for reviews, and one-time legacy migration.
@MainActor
final class SessionWorkspaceStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionWorkspaceStoreTests.\(UUID().uuidString)")
    }

    override func tearDown() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sessions.") || key.hasPrefix("sessionWorkspaces.") {
            defaults.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func makeDirectory(named name: String, git: Bool = false) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SWS-\(UUID().uuidString)")
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if git {
            try? FileManager.default.createDirectory(
                at: url.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return url
    }

    private func makeStore() -> SessionWorkspaceStore {
        SessionWorkspaceStore(defaults: defaults)
    }

    // MARK: - Set / clear

    func testSetFolderExposesOneWorkspaceAndDefault() {
        let store = makeStore()
        let directory = makeDirectory(named: "Alpha")
        store.setDefaultFolderPath(directory.path)

        XCTAssertEqual(store.defaultFolderPath, directory.standardizedFileURL.path)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.defaultWorkspaceID, store.workspaces.first?.id)
        XCTAssertEqual(store.availableWorkspaces.count, 1)
    }

    func testSetFolderIsCanonicalized() {
        let store = makeStore()
        let directory = makeDirectory(named: "Canonical")
        store.setDefaultFolderPath(directory.standardizedFileURL.path + "/")

        XCTAssertEqual(store.defaultFolderPath, CheckoutPath.canonical(directory))
    }

    func testClearingFolderRemovesTheWorkspaceEntry() {
        let store = makeStore()
        store.setDefaultFolderPath(makeDirectory(named: "Gone").path)
        store.setDefaultFolderPath(nil)

        XCTAssertTrue(store.defaultFolderPath.isEmpty)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.defaultWorkspaceID)
    }

    func testSameFolderKeepsStableIdentityAcrossReload() {
        let directory = makeDirectory(named: "Stable")
        let first = makeStore()
        first.setDefaultFolderPath(directory.path)
        let firstID = first.defaultWorkspaceID

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.defaultWorkspaceID, firstID)
    }

    func testDifferentFolderGetsFreshIdentity() {
        let store = makeStore()
        store.setDefaultFolderPath(makeDirectory(named: "A").path)
        let firstID = store.defaultWorkspaceID
        store.setDefaultFolderPath(makeDirectory(named: "B").path)

        XCTAssertNotEqual(store.defaultWorkspaceID, firstID)
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testUnavailableFolderYieldsNoAvailableWorkspaces() {
        let store = makeStore()
        let directory = makeDirectory(named: "Vanishing")
        store.setDefaultFolderPath(directory.path)
        try? FileManager.default.removeItem(at: directory)

        XCTAssertEqual(store.availableWorkspaces.count, 0)
        XCTAssertNotNil(store.defaultFolder)
    }

    // MARK: - Requirements

    func testReviewPurposeRequiresGitRepositoryOthersDoNot() {
        let store = makeStore()
        let plain = makeDirectory(named: "Plain")
        let gitly = makeDirectory(named: "Gitly", git: true)

        let plainWorkspace = SessionWorkspace(name: "Plain", directoryPath: plain.path)
        let gitWorkspace = SessionWorkspace(name: "Gitly", directoryPath: gitly.path)

        XCTAssertFalse(SessionWorkspaceStore.meetsRequirement(for: plainWorkspace, purpose: .review))
        XCTAssertTrue(SessionWorkspaceStore.meetsRequirement(for: plainWorkspace, purpose: .general))
        XCTAssertTrue(SessionWorkspaceStore.meetsRequirement(for: gitWorkspace, purpose: .review))
    }

    // MARK: - Migration

    func testLegacyDefaultWorkspaceBecomesSessionFolderPreservingIdentity() {
        let directory = makeDirectory(named: "Legacy")
        let legacy = SessionWorkspace(name: "Legacy", directoryPath: directory.path)
        registerLegacy([legacy], defaultID: legacy.id)

        let store = makeStore()
        XCTAssertEqual(store.defaultFolderPath, CheckoutPath.canonical(directory))
        XCTAssertEqual(store.defaultWorkspaceID, legacy.id)
        XCTAssertEqual(store.availableWorkspaces.count, 1)
    }

    func testLegacySoleEntryWithoutDefaultIsAdopted() {
        let directory = makeDirectory(named: "Only")
        let legacy = SessionWorkspace(name: "Only", directoryPath: directory.path)
        registerLegacy([legacy], defaultID: nil)

        let store = makeStore()
        XCTAssertEqual(store.defaultWorkspaceID, legacy.id)
    }

    func testAmbiguousLegacyDataIsLeftUnset() {
        let legacy = [
            SessionWorkspace(name: "One", directoryPath: makeDirectory(named: "One").path),
            SessionWorkspace(name: "Two", directoryPath: makeDirectory(named: "Two").path),
        ]
        registerLegacy(legacy, defaultID: nil)

        let store = makeStore()
        XCTAssertTrue(store.defaultFolderPath.isEmpty)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    func testMigrationNeverReimportsAfterClearing() {
        let directory = makeDirectory(named: "Once")
        let legacy = SessionWorkspace(name: "Once", directoryPath: directory.path)
        registerLegacy([legacy], defaultID: legacy.id)
        _ = makeStore()

        let second = makeStore()
        second.setDefaultFolderPath(nil)
        let third = makeStore()
        XCTAssertTrue(third.defaultFolderPath.isEmpty)
        XCTAssertTrue(third.workspaces.isEmpty)
    }

    private func registerLegacy(_ workspaces: [SessionWorkspace], defaultID: UUID?) {
        let data = try! JSONEncoder().encode(workspaces)
        defaults.set(data, forKey: "sessionWorkspaces.list")
        if let defaultID {
            defaults.set(defaultID.uuidString, forKey: "sessionWorkspaces.defaultID")
        }
    }
}