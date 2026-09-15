import XCTest
@testable import Console

@MainActor
final class WorkItemAssociationTests: XCTestCase {
    private func record(_ purpose: SessionPurpose = .existingTicket, id: UUID = UUID(), name: String = "Work") -> SessionRestorationRecord {
        .init(claudeSessionID: id, name: name, workingDirectory: URL(fileURLWithPath: "/tmp"), purpose: purpose)
    }
    private func jira(_ host: String = "jira.test", key: String = "ENG-42") -> SessionArtifact {
        .init(kind: .jiraIssue, label: key, url: URL(string: "https://\(host)/browse/\(key)")!)
    }
    private func mr(_ project: String = "team/project", iid: Int = 1) -> SessionArtifact {
        .init(kind: .gitlabMergeRequest, label: "!\(iid)", url: URL(string: "https://gitlab.test/\(project)/-/merge_requests/\(iid)")!)
    }

    func testImplementationGroupsConversationsAndMultipleMRsUnderStableWorkIdentity() throws {
        let store = SessionAssociationStore(url: nil)
        let first = record(), second = record()
        try store.remember(record: first, artifacts: [jira(), mr()])
        let id = try XCTUnwrap(store.workItems.first?.id)
        try store.remember(record: second, artifacts: [jira(), mr(iid: 2)])
        XCTAssertEqual(store.workItems.count, 1)
        XCTAssertEqual(store.workItems[0].id, id)
        XCTAssertEqual(store.workItems[0].sessions.count, 2)
        XCTAssertEqual(store.artifacts(for: first.id).count, 3)
        XCTAssertNil(store.author(for: mr().url!), "Multiple authoring conversations require a remembered choice")
        try store.preferAuthor(first.id, for: mr().url!)
        XCTAssertEqual(store.author(for: mr().url!)?.id, first.id)
        try store.remember(record: record(id: first.id, name: "Renamed"), artifacts: [])
        XCTAssertEqual(store.workItems[0].id, id)
        XCTAssertEqual(store.ticketKeys()[first.id], "ENG-42")
    }

    func testReviewAndImplementationAreDistinctEvenForSameMRAndStory() throws {
        let store = SessionAssociationStore(url: nil)
        let author = record(), reviewer = record(.review)
        try store.remember(record: author, artifacts: [jira(), mr()])
        try store.remember(record: reviewer, artifacts: [jira(), mr()])
        XCTAssertEqual(store.workItems.count, 2)
        XCTAssertEqual(store.author(for: mr().url!)?.id, author.id)
        XCTAssertEqual(store.review(for: mr().url!)?.id, reviewer.id)
        XCTAssertEqual(store.conversationIDs(for: jira().url!, kind: .jiraIssue, role: .author), [author.id])
    }

    func testReviewWithoutJiraSurvivesReloadAndDoesNotGuessAmongConversations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.json")
        let store = SessionAssociationStore(url: url)
        let first = record(.review)
        try store.remember(record: first, artifacts: [mr()])
        let reloaded = SessionAssociationStore(url: url)
        XCTAssertEqual(reloaded.review(for: mr().url!)?.id, first.id)
        XCTAssertTrue(reloaded.ticketKeys().isEmpty)
        try reloaded.remember(record: record(.review), artifacts: [mr()])
        XCTAssertEqual(reloaded.workItems.count, 1)
        XCTAssertNil(reloaded.review(for: mr().url!))
    }

    func testCanonicalArtifactIdentityIgnoresLabelsQueryFragmentsAndDefaultPorts() throws {
        let store = SessionAssociationStore(url: nil)
        let session = record()
        try store.remember(record: session, artifacts: [jira(), mr()])
        let chips = store.artifacts(for: session.id)
        try store.remember(record: session, artifacts: [
            .init(kind: .jiraIssue, label: "A new title", url: URL(string: "https://JIRA.TEST:443/browse/ENG-42?x=1#notes")!),
            .init(kind: .gitlabMergeRequest, label: "MR !1", url: URL(string: "https://GITLAB.TEST:443/team/project/-/merge_requests/1/diffs?view=parallel#note_42")!)])
        XCTAssertEqual(store.artifacts(for: session.id).count, 2)
        XCTAssertEqual(store.artifacts(for: session.id).map(\.id), chips.map(\.id))
        XCTAssertEqual(store.ticketKeys()[session.id], "ENG-42", "A display label is not ticket identity")
    }

    func testSameKeysOnDifferentSitesAndSameIIDsInDifferentProjectsStaySeparate() throws {
        let store = SessionAssociationStore(url: nil)
        let first = record(), second = record()
        try store.remember(record: first, artifacts: [jira(), mr()])
        try store.remember(record: second, artifacts: [jira("other.test"), mr("other/project")])
        XCTAssertEqual(store.workItems.count, 2)
        XCTAssertEqual(store.conversationIDs(for: jira().url!, kind: .jiraIssue), [first.id])
        XCTAssertEqual(store.author(for: mr("other/project").url!)?.id, second.id)
    }

    func testLegacyTicketOnlyLinksRemainUnscopedAndImportOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.json")
        let a = UUID(), b = UUID()
        let store = SessionAssociationStore(url: url, legacyTickets: [a: "ENG-42", b: "ENG-42"])
        XCTAssertEqual(store.workItems.count, 2)
        XCTAssertEqual(store.ticketKeys(), [a: "ENG-42", b: "ENG-42"])
        XCTAssertTrue(store.conversationIDs(for: jira().url!, kind: .jiraIssue).isEmpty)
        let reloaded = SessionAssociationStore(url: url, legacyTickets: [a: "ENG-99", UUID(): "ENG-123"])
        XCTAssertEqual(reloaded.workItems, store.workItems)
    }

    func testVersionOneMigrationPreservesExplicitPreferenceButNotGuessedAuthorship() throws {
        struct Legacy: Encodable {
            let version = 1
            let conversations: [SessionAssociationStore.Conversation]
            let preferredAuthors: [String: UUID]
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.json")
        let author = record(.general), reviewer = record(.review), unknown = record(.general)
        let legacy = Legacy(conversations: [
            .init(record: author, artifacts: [jira(), mr()], updatedAt: Date()),
            .init(record: reviewer, artifacts: [mr()], updatedAt: Date()),
            .init(record: unknown, artifacts: [mr(iid: 2)], updatedAt: Date())],
            preferredAuthors: [mr().url!.absoluteString: author.id])
        try JSONEncoder().encode(legacy).write(to: url)
        let store = SessionAssociationStore(url: url)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.author(for: mr().url!)?.id, author.id)
        XCTAssertEqual(store.review(for: mr().url!)?.id, reviewer.id)
        XCTAssertNil(store.author(for: mr(iid: 2).url!))
        XCTAssertEqual(store.artifacts(for: unknown.id).count, 1)
        let reloaded = SessionAssociationStore(url: url)
        XCTAssertEqual(reloaded.workItems, store.workItems)
    }

    func testExplicitAuthorRoleSurvivesGenericConversationUpdates() throws {
        let store = SessionAssociationStore(url: nil)
        let author = record(.general)
        try store.remember(record: author, artifacts: [mr()], authoredMR: mr().url!)
        let id = store.workItems[0].id
        try store.remember(record: record(.general, id: author.id, name: "New name"), artifacts: [])
        XCTAssertEqual(store.workItems.count, 1)
        XCTAssertEqual(store.workItems[0].id, id)
        XCTAssertEqual(store.author(for: mr().url!)?.id, author.id)
    }

    func testOneConversationCanAuthorAndReviewWithoutRolesSpreadingThroughChips() throws {
        let store = SessionAssociationStore(url: nil)
        let session = record(.review)
        let reviewed = mr(), authored = mr(iid: 2)
        try store.remember(record: session, artifacts: [reviewed])
        try store.remember(record: session, artifacts: [reviewed, authored], authoredMR: authored.url!)
        XCTAssertEqual(store.workItems.count, 2)
        XCTAssertNil(store.author(for: reviewed.url!))
        XCTAssertEqual(store.author(for: authored.url!)?.id, session.id)
        try store.remember(record: session, artifacts: store.artifacts(for: session.id))
        XCTAssertNil(store.review(for: authored.url!))
        XCTAssertEqual(store.review(for: reviewed.url!)?.id, session.id)
        XCTAssertEqual(store.artifacts(for: session.id).count, 2)
    }

    func testUnscopedTicketIsEnrichedWithinItsWorkWithoutDuplicateChips() throws {
        let store = SessionAssociationStore(url: nil)
        let session = record()
        try store.remember(record: session, artifacts: [.init(kind: .jiraIssue, label: "ENG-42")])
        let workID = store.workItems[0].id
        try store.remember(record: session, artifacts: [jira()])
        XCTAssertEqual(store.workItems[0].id, workID)
        XCTAssertEqual(store.artifacts(for: session.id).count, 1)
        XCTAssertEqual(store.artifacts(for: session.id).first?.url, jira().url)
    }

    func testFailedSaveRollsBackWorkItemsAndConversationTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAssociationStore(url: root.appendingPathComponent("work.json"))
        try Data("blocks directory creation".utf8).write(to: root)
        let session = record()
        XCTAssertThrowsError(try store.remember(record: session, artifacts: [jira(), mr()], authoredMR: mr().url!))
        XCTAssertTrue(store.workItems.isEmpty)
        XCTAssertNil(store.conversation(session.id))
        XCTAssertNil(store.author(for: mr().url!))
    }
}
