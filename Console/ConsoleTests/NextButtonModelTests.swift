import XCTest
@testable import Console

@MainActor
final class NextButtonModelTests: XCTestCase {

    /// Unique synthetic marker that must never leave the local Next path.
    private let sensitiveMarker = "SYN-NEXT-PRIVACY-MARKER-9f3c"

    // MARK: - Spies

    private final class RecordingLLMClient: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequests: [(systemPrompt: String, userMessage: String)] = []

        var requests: [(systemPrompt: String, userMessage: String)] {
            lock.withLock { storedRequests }
        }

        func sendMessage(systemPrompt: String, userMessage: String) async throws -> String {
            lock.withLock { storedRequests.append((systemPrompt, userMessage)) }
            XCTFail("Next must not send panel-derived text to an LLM client")
            return "{}"
        }
    }

    private final class RefreshProbe {
        private(set) var count = 0
        func run() async {
            count += 1
        }
    }

    // MARK: - Fixtures

    private func reviewSnapshot(title: String = "Synthetic review") -> NextContextSnapshot {
        let url = URL(string: "https://gitlab.example.com/p/r/-/merge_requests/12")!
        return NextContextSnapshot(
            reviewItems: [
                MergeRequestSummary(
                    id: url,
                    iidText: "12",
                    title: title,
                    projectDisplayName: "FixtureRepo",
                    authorDisplayName: "Someone Else",
                    isDraft: false,
                    pipelineDisplayState: nil,
                    reviewDisplayState: nil,
                    updatedText: nil,
                    mergeRequestURL: url,
                    sourceOrder: 0
                )
            ]
        )
    }

    private func ticketSnapshot(key: String, summary: String) -> NextContextSnapshot {
        NextContextSnapshot(
            tickets: [
                JiraTicketSummary(
                    key: key,
                    summary: summary,
                    status: "To Do",
                    priority: nil,
                    updatedText: nil,
                    issueURL: URL(string: "https://jira.example.com/browse/\(key)")!,
                    sourceOrder: 0
                )
            ]
        )
    }

    private func waitUntilReady(
        _ model: NextButtonModel,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = model.status { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for ready status, last: \(model.status)", file: file, line: line)
    }

    private func readyTask(_ model: NextButtonModel) -> NextTask? {
        if case .ready(let task, _) = model.status { return task }
        return nil
    }

    private func leakedMarkerLocations(_ marker: String, spy: RecordingLLMClient) -> [String] {
        var hits: [String] = []
        for (index, request) in spy.requests.enumerated() {
            if request.systemPrompt.contains(marker) {
                hits.append("spy.systemPrompt[\(index)]")
            }
            if request.userMessage.contains(marker) {
                hits.append("spy.userMessage[\(index)]")
            }
        }
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            let encoded: String?
            if let string = value as? String {
                encoded = string
            } else if let data = value as? Data {
                encoded = String(data: data, encoding: .utf8)
            } else {
                encoded = nil
            }
            if let encoded, encoded.contains(marker) {
                hits.append("UserDefaults.\(key)")
            }
        }
        return hits
    }

    // MARK: - Local recommendation without a provider

    func testCheckProducesReviewRecommendationWithoutProvider() async {
        let model = NextButtonModel()
        let refresh = RefreshProbe()
        let snapshot = reviewSnapshot()

        model.check(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        await waitUntilReady(model)

        let task = readyTask(model)
        XCTAssertEqual(task?.kind, .reviewMergeRequest)
        XCTAssertEqual(task?.targetURL?.absoluteString.contains("merge_requests/12"), true)
        XCTAssertEqual(refresh.count, 1)
        if case .ready(_, let fromAI) = model.status {
            XCTAssertFalse(fromAI)
        }
    }

    func testCheckProducesTicketRecommendationWithoutProvider() async {
        let model = NextButtonModel()
        let snapshot = ticketSnapshot(key: "SYN-7", summary: "Write the fixture")

        model.check(
            refresh: {},
            snapshot: { snapshot }
        )
        await waitUntilReady(model)

        let task = readyTask(model)
        XCTAssertEqual(task?.kind, .newTicket)
        XCTAssertEqual(task?.headline, "Start SYN-7")
        XCTAssertEqual(task?.targetURL?.absoluteString, "https://jira.example.com/browse/SYN-7")
    }

    // MARK: - Provider spy

    func testProviderSpyReceivesZeroRequestsOnOpenAndRefreshForEveryProvider() async {
        let manager = AIProviderManager()
        let previous = manager.selectedProvider
        defer { manager.selectedProvider = previous }

        for provider in AIProvider.allCases {
            manager.selectedProvider = provider
            XCTAssertEqual(manager.lastRequest, .none)

            let spy = RecordingLLMClient()
            let refresh = RefreshProbe()
            let model = NextButtonModel()
            let snapshot = reviewSnapshot(title: sensitiveMarker)

            model.checkIfNeeded(
                refresh: { await refresh.run() },
                snapshot: { snapshot },
                llmClient: spy
            )
            await waitUntilReady(model)
            XCTAssertEqual(spy.requests.count, 0, "open, provider \(provider)")
            XCTAssertEqual(manager.lastRequest, .none, "open lastRequest, provider \(provider)")
            XCTAssertEqual(refresh.count, 1, "open refresh, provider \(provider)")

            model.check(
                refresh: { await refresh.run() },
                snapshot: { snapshot },
                llmClient: spy
            )
            await waitUntilReady(model)
            XCTAssertEqual(spy.requests.count, 0, "refresh, provider \(provider)")
            XCTAssertEqual(manager.lastRequest, .none, "refresh lastRequest, provider \(provider)")
            XCTAssertEqual(refresh.count, 2, "second refresh, provider \(provider)")
        }
    }

    func testSensitiveMarkerNeverAppearsInSpyPayloadOrDefaults() async {
        let spy = RecordingLLMClient()
        let model = NextButtonModel()
        let snapshot = ticketSnapshot(key: "SYN-9", summary: sensitiveMarker)

        model.checkIfNeeded(
            refresh: {},
            snapshot: { snapshot },
            llmClient: spy
        )
        await waitUntilReady(model)
        model.check(
            refresh: {},
            snapshot: { snapshot },
            llmClient: spy
        )
        await waitUntilReady(model)

        XCTAssertEqual(spy.requests.count, 0)
        XCTAssertEqual(leakedMarkerLocations(sensitiveMarker, spy: spy), [])
        // The local card may still show the synthetic summary; that is in-process display.
        XCTAssertEqual(readyTask(model)?.lines.first, sensitiveMarker)
    }

    func testCheckDoesNotRecordProviderHTTPOutcome() async {
        let manager = AIProviderManager()
        let previous = manager.selectedProvider
        defer { manager.selectedProvider = previous }
        manager.selectedProvider = .openAI
        XCTAssertEqual(manager.lastRequest, .none)

        let spy = RecordingLLMClient()
        let model = NextButtonModel()
        let snapshot = reviewSnapshot(title: sensitiveMarker)
        model.check(
            refresh: {},
            snapshot: { snapshot },
            llmClient: spy
        )
        await waitUntilReady(model)

        XCTAssertEqual(manager.lastRequest, .none)
        XCTAssertEqual(spy.requests.count, 0)
    }

    // MARK: - Freshness / refresh

    func testCheckIfNeededSkipsWhenReadyAndFresh() async {
        let refresh = RefreshProbe()
        let model = NextButtonModel()
        let snapshot = reviewSnapshot()

        model.checkIfNeeded(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        await waitUntilReady(model)
        XCTAssertEqual(refresh.count, 1)

        model.checkIfNeeded(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        XCTAssertEqual(refresh.count, 1)
        if case .ready = model.status {
            // still ready; no second pass
        } else {
            XCTFail("Expected ready status to be preserved")
        }
    }

    func testCancelDuringRefreshLeavesIdleAndNeverCallsProvider() async {
        let spy = RecordingLLMClient()
        let model = NextButtonModel()
        let snapshot = reviewSnapshot(title: sensitiveMarker)
        var resumeRefresh: CheckedContinuation<Void, Never>?

        model.check(
            refresh: {
                await withCheckedContinuation { continuation in
                    resumeRefresh = continuation
                }
            },
            snapshot: { snapshot },
            llmClient: spy
        )

        let deadline = Date().addingTimeInterval(2)
        while resumeRefresh == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(resumeRefresh)
        XCTAssertEqual(model.status, .checking)

        model.cancel()
        resumeRefresh?.resume()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(spy.requests.count, 0)
        XCTAssertEqual(model.checkStartCount, 1)
    }

    // MARK: - Shared model / suspended duplicate work

    func testSecondCheckWhileSuspendedDoesNotStartDuplicateWork() async {
        let model = NextButtonModel()
        let snapshot = reviewSnapshot()
        var resumeRefresh: CheckedContinuation<Void, Never>?
        var refreshStarts = 0

        model.check(
            refresh: {
                refreshStarts += 1
                await withCheckedContinuation { continuation in
                    resumeRefresh = continuation
                }
            },
            snapshot: { snapshot }
        )

        let deadline = Date().addingTimeInterval(2)
        while resumeRefresh == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(resumeRefresh)
        XCTAssertEqual(model.status, .checking)
        XCTAssertEqual(model.checkStartCount, 1)
        XCTAssertEqual(refreshStarts, 1)

        // Page Determine and card Refresh share this model; neither may start a
        // second pass while the first is still in flight.
        model.check(
            refresh: { refreshStarts += 1 },
            snapshot: { snapshot }
        )
        model.checkIfNeeded(
            refresh: { refreshStarts += 1 },
            snapshot: { snapshot }
        )

        XCTAssertEqual(model.status, .checking)
        XCTAssertEqual(model.checkStartCount, 1)
        XCTAssertEqual(refreshStarts, 1)

        resumeRefresh?.resume()
        await waitUntilReady(model)
        XCTAssertEqual(model.checkStartCount, 1)
        XCTAssertEqual(refreshStarts, 1)
        XCTAssertEqual(readyTask(model)?.kind, .reviewMergeRequest)
    }

    func testExplicitRefreshAfterReadyStartsExactlyOneNewCheck() async {
        let refresh = RefreshProbe()
        let model = NextButtonModel()
        let snapshot = reviewSnapshot()

        model.check(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        await waitUntilReady(model)
        XCTAssertEqual(refresh.count, 1)
        XCTAssertEqual(model.checkStartCount, 1)

        model.check(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        await waitUntilReady(model)
        XCTAssertEqual(refresh.count, 2)
        XCTAssertEqual(model.checkStartCount, 2)
        if case .ready = model.status {
            // same card, updated by the second pass
        } else {
            XCTFail("Expected ready status after the second check")
        }
    }

    func testCheckIfNeededPreservesCheckStartCountWhenFresh() async {
        let refresh = RefreshProbe()
        let model = NextButtonModel()
        let snapshot = reviewSnapshot()

        model.checkIfNeeded(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        await waitUntilReady(model)
        XCTAssertEqual(model.checkStartCount, 1)

        model.checkIfNeeded(
            refresh: { await refresh.run() },
            snapshot: { snapshot }
        )
        XCTAssertEqual(refresh.count, 1)
        XCTAssertEqual(model.checkStartCount, 1)
    }

    func testGatherSnapshotWithMissingSessionStoreUsesEmptySessions() {
        let snapshot = NextButtonModel.gatherSnapshot(
            sessionStore: nil,
            jiraController: JiraPanelController()
        )
        XCTAssertEqual(snapshot.sessions, [])
    }

    func testProductionCheckWithNilSessionStoreUsesInjectedSnapshot() async {
        let model = NextButtonModel()
        let refresh = RefreshProbe()
        model.refreshHandler = { await refresh.run() }
        model.snapshotHandler = { self.reviewSnapshot() }

        model.check(sessionStore: nil, jiraController: JiraPanelController())
        await waitUntilReady(model)

        XCTAssertEqual(readyTask(model)?.kind, .reviewMergeRequest)
        XCTAssertEqual(refresh.count, 1)
        XCTAssertEqual(model.checkStartCount, 1)
    }

    func testPerformOpenNavigatesWithoutStartingAnotherCheck() async {
        let model = NextButtonModel()
        let snapshot = reviewSnapshot()
        model.check(refresh: {}, snapshot: { snapshot })
        await waitUntilReady(model)
        let starts = model.checkStartCount

        XCTAssertEqual(model.performOpen(sessionStore: nil), .mergeRequests)
        XCTAssertEqual(model.checkStartCount, starts)
        if case .ready = model.status {
            // Open does not clear or re-check the card
        } else {
            XCTFail("Open must not change the ready status")
        }
    }

    func testPerformOpenDoesNothingWhenNotReady() {
        let model = NextButtonModel()
        XCTAssertNil(model.performOpen(sessionStore: nil))
        XCTAssertEqual(model.checkStartCount, 0)
        XCTAssertEqual(model.status, .idle)
    }
}
