import XCTest
@testable import Console

@MainActor
final class AuthoredMRAttentionTests: XCTestCase {
    private let scope = URL(string: "https://gitlab.example.test/dashboard/merge_requests")!
    private final class ScanFixture {
        var authored: [AuthoredMRAttention] = []
        var complete = true
        var reviewsComplete = true
        var username = "me"
        var url = ""
    }

    private func item(discussions: Int = 1, approvals: Int = 1, satisfied: Bool = true,
                      author: String = "me", host: String = "gitlab.example.test", iid: Int = 1) -> AuthoredMRAttention {
        .init(project: "team/project", iid: iid,
              url: URL(string: "https://\(host)/team/project/-/merge_requests/\(iid)")!,
              title: "ENG-42 Work", authorUsername: author, state: "opened",
              unresolvedDiscussionCount: discussions, externalApprovalCount: approvals,
              approvalRulesSatisfied: satisfied, jiraIssueKey: "ENG-42")
    }

    func testBothConditionsAndApprovalRequirements() {
        XCTAssertTrue(item().hasDiscussions)
        XCTAssertTrue(item().isApproved)
        XCTAssertFalse(item(approvals: 0).isApproved, "Zero required approvals alone is not approval")
        XCTAssertFalse(item(satisfied: false).isApproved)
        XCTAssertFalse(item(discussions: 0).hasDiscussions)
    }

    func testRejectsForeignIdentityDuplicatesAndIncompleteEvidence() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let invocation = try MRReviewTriagePrompt.invocation(url: scope, executable: "/bin/glab", defaults: defaults)
        func decode(_ items: [AuthoredMRAttention], complete: Bool = true) throws -> [AuthoredMRAttention] {
            let result = MRReviewTriageResult(complete: false, failure: "api", currentUsername: "me", items: [],
                authoredComplete: complete, authoredItems: items)
            let output = ClaudeOperationOutput(correlationID: invocation.correlationID,
                resultText: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), sessionID: nil)
            return try AuthoredMRAttention.decode(output, invocation: invocation, scope: scope)
        }
        XCTAssertEqual(try decode([item()]).count, 1, "Review failure must not invalidate authored evidence")
        XCTAssertThrowsError(try decode([item(author: "someoneElse")]))
        XCTAssertThrowsError(try decode([item(host: "other.test")]))
        XCTAssertThrowsError(try decode([item(), item()]))
        XCTAssertThrowsError(try decode([item()], complete: false))
        XCTAssertThrowsError(try decode([item(discussions: -1)]))
    }

    func testSharedScanPublishesOverlapRetainsOnFailureAndClearsOnSuccess() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.scope.absoluteString },
            executableProvider: { "/bin/glab" })
        let fixture = ScanFixture()
        fixture.authored = [item()]
        source.configure { invocation in
            let result = MRReviewTriageResult(complete: fixture.reviewsComplete, failure: fixture.reviewsComplete ? nil : "api",
                currentUsername: "me", items: [], authoredComplete: fixture.complete, authoredItems: fixture.authored)
            return ClaudeOperationOutput(correlationID: invocation.correlationID,
                resultText: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), sessionID: nil)
        }
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.discussionItems.count, 1)
        XCTAssertEqual(source.approvedItems.count, 1)
        let stamp = source.authoredLastSuccessfulUpdate
        fixture.complete = false
        fixture.authored = []
        _ = await source.scan(trigger: .background)
        XCTAssertEqual(source.discussionItems.count, 1)
        XCTAssertEqual(source.authoredLastSuccessfulUpdate, stamp)
        XCTAssertNotNil(source.authoredMessage)
        fixture.complete = true
        fixture.reviewsComplete = false
        _ = await source.scan(trigger: .manual)
        XCTAssertTrue(source.discussionItems.isEmpty)
        XCTAssertTrue(source.approvedItems.isEmpty)
        XCTAssertNil(source.authoredMessage)
    }

    func testApprovedQueueConsumesInOrderAndRepopulatesOnlyWithCompleteAuthoredScan() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let fixture = ScanFixture()
        fixture.authored = [item(iid: 2), item(), item(approvals: 0, iid: 3)]
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.scope.absoluteString },
            executableProvider: { "/bin/glab" })
        source.configure { invocation in
            let result = MRReviewTriageResult(complete: fixture.reviewsComplete, failure: nil,
                currentUsername: fixture.username, items: [], authoredComplete: fixture.complete,
                authoredItems: fixture.authored)
            return ClaudeOperationOutput(correlationID: invocation.correlationID,
                resultText: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), sessionID: nil)
        }

        XCTAssertNil(source.dequeueApprovedNotification())
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.approvedItems.map(\.iid), [1, 2])
        XCTAssertEqual(source.dequeueApprovedNotification()?.iid, 1)
        XCTAssertEqual(source.approvedItems.map(\.iid), [2])
        XCTAssertEqual(source.discussionItems.count, 3)
        XCTAssertEqual(source.authoredItems.count, 3)

        fixture.complete = false
        _ = await source.scan(trigger: .background)
        XCTAssertEqual(source.approvedItems.map(\.iid), [2])
        XCTAssertEqual(source.dequeueApprovedNotification()?.iid, 2)
        XCTAssertTrue(source.approvedItems.isEmpty)
        XCTAssertNil(source.dequeueApprovedNotification())
        _ = await source.scan(trigger: .manual)
        XCTAssertTrue(source.approvedItems.isEmpty)

        fixture.complete = true
        fixture.reviewsComplete = false
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.approvedItems.map(\.iid), [1, 2])
        fixture.authored = []
        _ = await source.scan(trigger: .background)
        XCTAssertTrue(source.approvedItems.isEmpty)
    }

    func testDiscussionQueueConsumesInOrderAndRepopulatesOnlyWithCompleteAuthoredScan() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let fixture = ScanFixture()
        fixture.authored = [item(iid: 2), item(), item(discussions: 0, iid: 3)]
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.scope.absoluteString },
            executableProvider: { "/bin/glab" })
        source.configure { invocation in
            let result = MRReviewTriageResult(complete: fixture.reviewsComplete, failure: nil,
                currentUsername: fixture.username, items: [], authoredComplete: fixture.complete,
                authoredItems: fixture.authored)
            return ClaudeOperationOutput(correlationID: invocation.correlationID,
                resultText: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), sessionID: nil)
        }

        XCTAssertNil(source.dequeueDiscussionNotification())
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.discussionItems.map(\.iid), [1, 2])
        XCTAssertEqual(source.dequeueDiscussionNotification()?.iid, 1)
        XCTAssertEqual(source.discussionItems.map(\.iid), [2])
        XCTAssertEqual(source.dequeueDiscussionNotification()?.iid, 2)
        XCTAssertTrue(source.discussionItems.isEmpty)
        XCTAssertNil(source.dequeueDiscussionNotification())

        fixture.complete = false
        _ = await source.scan(trigger: .background)
        XCTAssertTrue(source.discussionItems.isEmpty, "An incomplete scan must not repopulate consumed notifications")

        fixture.complete = true
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.discussionItems.map(\.iid), [1, 2], "A complete scan repopulates the queue")
    }

    func testCatalogPersistsScopeRoleAndExplicitPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("associations.json")
        let store = SessionAssociationStore(url: url)
        let mr = item().url
        let author = SessionRestorationRecord(claudeSessionID: UUID(), name: "Author", workingDirectory: root, purpose: .general)
        let reviewer = SessionRestorationRecord(claudeSessionID: UUID(), name: "Review", workingDirectory: root, purpose: .review)
        let artifacts: [SessionArtifact] = [.init(kind: .gitlabMergeRequest, label: "!1", url: mr),
                                           .init(kind: .jiraIssue, label: "ENG-42", url: URL(string: "https://jira.test/browse/ENG-42"))]
        try store.remember(record: reviewer, artifacts: artifacts)
        XCTAssertNil(store.author(for: mr))
        try store.remember(record: author, artifacts: artifacts, authoredMR: mr)
        XCTAssertEqual(store.author(for: mr)?.id, author.id)
        XCTAssertNil(store.author(for: URL(string: "https://other.test/team/project/-/merge_requests/1")!))
        let second = SessionRestorationRecord(claudeSessionID: UUID(), name: "Follow-up", workingDirectory: root, purpose: .general)
        try store.remember(record: second, artifacts: artifacts)
        XCTAssertEqual(store.author(for: mr)?.id, author.id, "A generic related conversation must not displace an explicit author")
        try store.preferAuthor(second.id, for: mr)
        let reloaded = SessionAssociationStore(url: url)
        XCTAssertEqual(reloaded.author(for: mr)?.id, second.id)
        XCTAssertEqual(reloaded.author(for: mr)?.artifacts.count, 2)
        try reloaded.remember(record: second, artifacts: [])
        XCTAssertEqual(reloaded.author(for: mr)?.artifacts.count, 2, "Resuming must retain work links")
    }

    func testUnreadableCatalogIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("not valid JSON".utf8)
        try original.write(to: url)
        let store = SessionAssociationStore(url: url)
        XCTAssertThrowsError(try store.remember(record: .init(claudeSessionID: UUID(), name: "Work",
            workingDirectory: url.deletingLastPathComponent(), purpose: .general), artifacts: []))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testScopeAndAccountChangesDoNotRetainAnotherUsersBadges() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let fixture = ScanFixture()
        fixture.url = scope.absoluteString
        let source = MRReviewScanController(defaults: defaults, urlProvider: { fixture.url }, executableProvider: { "/bin/glab" })
        source.configure { invocation in
            let result = MRReviewTriageResult(complete: true, failure: nil, currentUsername: fixture.username, items: [],
                authoredComplete: fixture.complete, authoredItems: fixture.complete ? [self.item(author: fixture.username)] : [])
            return ClaudeOperationOutput(correlationID: invocation.correlationID,
                resultText: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), sessionID: nil)
        }
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.discussionItems.count, 1)
        fixture.username = "otherUser"
        fixture.complete = false
        _ = await source.scan(trigger: .manual)
        XCTAssertTrue(source.discussionItems.isEmpty)
        XCTAssertTrue(source.approvedItems.isEmpty)
        XCTAssertNil(source.authoredLastSuccessfulUpdate)
        fixture.complete = true
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.discussionItems.count, 1)
        fixture.url = "https://other.example.test/dashboard/merge_requests"
        source.settingsChanged()
        XCTAssertTrue(source.discussionItems.isEmpty)
        XCTAssertTrue(source.approvedItems.isEmpty)
    }
}
