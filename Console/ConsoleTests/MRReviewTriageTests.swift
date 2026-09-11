import XCTest
@testable import Console

@MainActor
final class MRReviewTriageTests: XCTestCase {
    private let scope = URL(string: "https://gitlab.example.test/groups/team/-/merge_requests?reviewer_username=me")!
    private var defaults: UserDefaults!
    private var suite: String!
    private var dynamicURL = ""

    override func setUp() {
        super.setUp()
        suite = "MRReviewTriageTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func item(_ iid: Int = 1, category: MRReviewCategory = .needsReview,
                      author: String = "author", draft: Bool = false, approved: Bool = false,
                      state: String = "opened", myComment: String? = nil,
                      activity: String? = nil, url: URL? = nil) -> MRReviewTriageItem {
        MRReviewTriageItem(project: "team/project", iid: iid,
            url: url ?? URL(string: "https://gitlab.example.test/team/project/-/merge_requests/\(iid)")!,
            title: "MR \(iid)", author: author, authorUsername: author, state: state,
            draft: draft, approved: approved, category: category, reason: "Evidence from GitLab",
            hasDeveloperComments: category != .needsReview, latestMyCommentAt: myComment,
            latestAuthorActivityAt: activity)
    }

    private func output(_ invocation: ClaudeOperationInvocation, items: [MRReviewTriageItem], complete: Bool = true) throws -> ClaudeOperationOutput {
        let result = MRReviewTriageResult(complete: complete, failure: complete ? nil : "api", currentUsername: "me", items: items)
        return ClaudeOperationOutput(correlationID: invocation.correlationID,
            resultText: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), sessionID: nil)
    }

    private func decode(_ items: [MRReviewTriageItem]) throws -> [MergeRequestSummary] {
        let invocation = try MRReviewTriagePrompt.invocation(url: scope, executable: "/opt/homebrew/bin/glab", defaults: defaults)
        return try MRReviewTriagePrompt.decode(output(invocation, items: items), invocation: invocation, scope: scope)
    }

    func testPriorityAndExclusionsBeforeNineCardLimit() throws {
        var items = (1...12).map { item($0) }
        items += [item(20, category: .alreadyReviewed),
                  item(21, category: .activeReview, myComment: "2026-09-09T12:00:00Z", activity: "2026-09-10T12:00:00.000Z"),
                  item(22, author: "ME"), item(23, draft: true), item(24, approved: true),
                  item(25, state: "merged"), item(26, state: "closed"),
                  item(27, category: .activeReview, approved: true, myComment: "2026-09-09T12:00:00Z", activity: "2026-09-10T12:00:00Z")]
        let decoded = try decode(items.reversed())
        XCTAssertEqual(decoded.count, 14, "Discovery is not limited to visible cards")
        let queue = HomeBoardBuilder.reviewQueue(in: decoded)
        XCTAssertEqual(queue.first?.iidText, "21")
        XCTAssertEqual(queue.last?.iidText, "20")
        XCTAssertEqual(queue.prefix(HomeView.maxReviewRequests).count, 9)
        XCTAssertEqual(HomeView.maxInProgressStories, 9)
    }

    func testLatestCommentResetsActiveReviewAndEqualDatesDoNotTrigger() throws {
        let oldActivity = item(category: .alreadyReviewed, myComment: "2026-09-10T12:00:00Z", activity: "2026-09-09T12:00:00Z")
        XCTAssertEqual(try decode([oldActivity]).first?.triageCategory, .alreadyReviewed)
        XCTAssertThrowsError(try decode([item(category: .activeReview,
            myComment: "2026-09-10T12:00:00Z", activity: "2026-09-10T12:00:00Z")]))
        XCTAssertThrowsError(try decode([item(category: .activeReview, activity: "2026-09-10T12:00:00Z")]))
    }

    func testRejectsDuplicatesForeignURLsAndMalformedDatesWithoutTrapping() throws {
        XCTAssertThrowsError(try decode([item(), item()]))
        XCTAssertThrowsError(try decode([item(url: URL(string: "https://elsewhere.test/team/project/-/merge_requests/1")!)]))
        XCTAssertThrowsError(try decode([item(url: URL(string: "https://gitlab.example.test/team/project/-/merge_requests/2")!)]))
        XCTAssertThrowsError(try decode([item(category: .alreadyReviewed, myComment: "yesterday")]))
    }

    func testPromptUsesNewPreferenceReadOnlyGLabAndCompleteDiscovery() throws {
        defaults.set("Do not use tools or fetch additional data.", forKey: AppSettings.mrDispositionPromptKey)
        let invocation = try MRReviewTriagePrompt.invocation(url: scope, executable: "/opt/homebrew/bin/glab", defaults: defaults)
        XCTAssertFalse(invocation.prompt.contains("Do not use tools or fetch additional data."))
        XCTAssertTrue(invocation.prompt.contains("--paginate"))
        XCTAssertTrue(invocation.prompt.contains("No other commands or tools"))
        XCTAssertTrue(invocation.prompt.contains("never diffs") || invocation.prompt.contains("Do not fetch diffs"))
        XCTAssertEqual(invocation.allowedToolsOverride, ["Bash"])
        XCTAssertEqual(invocation.toolPermissionRules, ["Bash(/opt/homebrew/bin/glab api --method GET *)"])
        XCTAssertFalse(try XCTUnwrap(invocation.expectedSchemaJSON).contains("\"version\""))
        defaults.set("Custom policy", forKey: MRReviewTriagePrompt.settingsKey)
        XCTAssertEqual(MRReviewTriagePrompt.configuredText(defaults), "Custom policy")
    }

    func testPermissionRulesAreSeparateFromAvailableTools() {
        let built = HeadlessInvocationBuilder.arguments(options: .init(model: "haiku", maxTurns: 100,
            allowedTools: ["Bash"], sessionID: UUID(), resume: false, ephemeral: true,
            expectedSchemaJSON: "{}", mcpConfigPath: nil,
            toolPermissionRules: ["Bash(/opt/homebrew/bin/glab api --method GET *)"]), supportedFlags: nil)
        XCTAssertTrue(built.arguments.contains("--allowedTools"))
        XCTAssertTrue(built.arguments.contains("Bash(/opt/homebrew/bin/glab api --method GET *)"))
        XCTAssertFalse(built.arguments.contains("--dangerously-skip-permissions"))
    }

    func testFailuresKeepCardsAndTimestampWhileSuccessfulEmptyClears() async throws {
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.scope.absoluteString },
            executableProvider: { "/opt/homebrew/bin/glab" })
        source.configure { try self.output($0, items: [self.item()]) }
        let first = await source.scan(trigger: .manual)
        XCTAssertEqual(first, .refreshed(1))
        let timestamp = source.lastSuccessfulUpdate
        source.configure { invocation in
            XCTAssertEqual(source.items.count, 1)
            XCTAssertEqual(source.status.check, .pending)
            return try self.output(invocation, items: [], complete: false)
        }
        let failed = await source.scan(trigger: .background)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(source.items.count, 1)
        XCTAssertEqual(source.lastSuccessfulUpdate, timestamp)
        XCTAssertEqual(source.status.check, .stale)
        source.configure { ClaudeOperationOutput(correlationID: $0.correlationID, resultText: "not JSON", sessionID: nil) }
        _ = await source.scan(trigger: .manual)
        XCTAssertEqual(source.items.count, 1)
        source.configure { try self.output($0, items: []) }
        let empty = await source.scan(trigger: .manual)
        XCTAssertEqual(empty, .refreshed(0))
        XCTAssertTrue(source.items.isEmpty)
        XCTAssertEqual(source.status.check, .current)
    }

    func testMissingGLabManualPopupButBackgroundOnlyStatus() async {
        let source = MRReviewScanController(defaults: defaults, urlProvider: { "" }, executableProvider: { nil })
        _ = await source.scan(trigger: .background)
        XCTAssertNil(source.manualError)
        let scheduler = MRReviewScanScheduler(defaults: defaults, reviewsURLProvider: { "" }, source: source)
        scheduler.scanNow()
        XCTAssertTrue(source.manualError?.contains("brew install glab") == true)
    }

    func testScopeChangeClearsOldCardsButCadenceChangeDoesNotMarkThemStale() async throws {
        dynamicURL = scope.absoluteString
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.dynamicURL }, executableProvider: { "/opt/homebrew/bin/glab" })
        source.configure { try self.output($0, items: [self.item()]) }
        _ = await source.scan(trigger: .manual)
        defaults.set(30, forKey: AppSettings.mrScanIntervalMinutesKey)
        source.settingsChanged()
        XCTAssertEqual(source.status.check, .current)
        XCTAssertEqual(source.items.count, 1)
        dynamicURL = "https://gitlab.example.test/groups/other/-/merge_requests"
        source.settingsChanged()
        XCTAssertTrue(source.items.isEmpty)
        XCTAssertNil(source.lastSuccessfulUpdate)
    }

    func testCancellationRetainsLastSuccessfulCards() async throws {
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.scope.absoluteString }, executableProvider: { "/opt/homebrew/bin/glab" })
        source.configure { try self.output($0, items: [self.item()]) }
        _ = await source.scan(trigger: .manual)
        let timestamp = source.lastSuccessfulUpdate
        var entered = false
        source.configure { invocation in
            entered = true
            try await Task.sleep(for: .seconds(30))
            return try self.output(invocation, items: [])
        }
        let task = Task { await source.scan(trigger: .manual) }
        await waitFor { entered }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(source.items.count, 1)
        XCTAssertEqual(source.lastSuccessfulUpdate, timestamp)
        XCTAssertFalse(source.isScanning)
    }

    func testInFlightDeduplicationAndDiscardAfterConfigurationChange() async throws {
        dynamicURL = scope.absoluteString
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.dynamicURL }, executableProvider: { "/opt/homebrew/bin/glab" })
        var continuation: CheckedContinuation<Void, Never>?
        source.configure { invocation in
            await withCheckedContinuation { continuation = $0 }
            return try self.output(invocation, items: [self.item()])
        }
        let task = Task { await source.scan(trigger: .manual) }
        await waitFor { continuation != nil }
        let duplicate = await source.scan(trigger: .manual)
        XCTAssertEqual(duplicate, .alreadyRefreshing)
        dynamicURL = "https://gitlab.example.test/groups/other/-/merge_requests"
        source.settingsChanged()
        continuation?.resume()
        let discarded = await task.value
        XCTAssertEqual(discarded, .cancelled)
        XCTAssertTrue(source.items.isEmpty)
        XCTAssertNil(source.lastSuccessfulUpdate)
    }

    func testHomeRefreshOnlyWhenStaleAndWorksWithTimerOff() async throws {
        var now = Date()
        let source = MRReviewScanController(defaults: defaults, urlProvider: { self.scope.absoluteString },
            executableProvider: { "/opt/homebrew/bin/glab" }, now: { now })
        var scans = 0
        source.configure { invocation in
            scans += 1
            return try self.output(invocation, items: [])
        }
        let scheduler = MRReviewScanScheduler(defaults: defaults, reviewsURLProvider: { self.scope.absoluteString }, source: source, now: { now })
        scheduler.scanOnAppearance()
        await waitFor { !scheduler.isScanning }
        XCTAssertEqual(scans, 1)
        scheduler.scanOnAppearance()
        XCTAssertFalse(scheduler.isScanning)
        XCTAssertEqual(scans, 1)
        now = now.addingTimeInterval(900)
        scheduler.scanOnAppearance()
        await waitFor { !scheduler.isScanning }
        XCTAssertEqual(scans, 2)
        scheduler.scanNow()
        await waitFor { !scheduler.isScanning }
        XCTAssertEqual(scans, 3)
        scheduler.stop()
    }

    private func waitFor(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(predicate())
    }

    /// Opt-in: uses the real managed Claude transport and authenticated GitLab, never logs MR content.
    func testLiveGLabScan() async throws {
        guard let raw = ProcessInfo.processInfo.environment["CONSOLE_LIVE_GLAB_URL"],
              let url = MRReviewTriagePrompt.configuredURL(raw) else {
            throw XCTSkip("Set TEST_RUNNER_CONSOLE_LIVE_GLAB_URL to run the authenticated integration check")
        }
        let executable = try XCTUnwrap(GLabExecutable.resolve())
        let service = ManagedClaudeService()
        defer { service.cleanupForAppQuit() }
        let invocation = try MRReviewTriagePrompt.invocation(url: url, executable: executable, defaults: defaults)
        let response = try await service.perform(invocation)
        let result = try JSONDecoder().decode(MRReviewTriageResult.self, from: Data(try XCTUnwrap(response.resultText).utf8))
        XCTAssertTrue(result.complete, "Live scan incomplete: \(result.failure ?? "unknown")")
        _ = try MRReviewTriagePrompt.decode(response, invocation: invocation, scope: url)
    }
}
