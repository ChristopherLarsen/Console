import XCTest
@testable import Console

@MainActor
final class MRReviewDispositionTests: XCTestCase {
    private func card(_ index: Int = 0, state: String? = "Approved") -> MergeRequestSummary {
        let url = URL(string: "https://gitlab.example.test/project/-/merge_requests/\(index)")!
        return MergeRequestSummary(
            id: url, iidText: "\(index)", title: "Synthetic change \(index)",
            projectDisplayName: "Fixture", authorDisplayName: "Fixture author", isDraft: false,
            pipelineDisplayState: "Passed", reviewDisplayState: state, updatedText: nil,
            mergeRequestURL: url, sourceOrder: index
        )
    }

    private func defaults() -> UserDefaults {
        let name = "MRReviewDispositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func response(_ invocation: ClaudeOperationInvocation, ids: [String]? = nil) throws -> ClaudeOperationOutput {
        let dataText = try XCTUnwrap(invocation.prompt.components(separatedBy: "CARD_DATA_JSON:\n").last)
        let cards = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dataText.utf8)) as? [[String: Any]])
        let ids = ids ?? cards.compactMap { $0["id"] as? String }
        let object: [String: Any] = [
            "correlationID": invocation.correlationID.uuidString,
            "items": ids.reversed().map { ["id": $0, "disposition": "Approved"] }
        ]
        return ClaudeOperationOutput(
            correlationID: invocation.correlationID,
            resultText: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self),
            sessionID: nil
        )
    }

    private func settle(_ controller: MRReviewDispositionController) async {
        for _ in 0..<400 {
            if !controller.isClassifying { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Disposition task did not settle")
    }

    func testBatchesEveryCardAndKeepsSourceUntouched() async {
        let defaults = defaults()
        defaults.set("haiku", forKey: AppSettings.mrScanModelKey)
        var requests: [ClaudeOperationInvocation] = []
        let controller = MRReviewDispositionController(defaults: defaults, notificationCenter: NotificationCenter()) { invocation in
            requests.append(invocation)
            return try self.response(invocation)
        }
        defer { controller.shutdown() }
        let items = (0..<41).map { card($0) }
        controller.update(items)
        await settle(controller)
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(items.allSatisfy { controller.disposition(for: $0) == .approved })
        XCTAssertEqual(items[0].reviewDisplayState, "Approved")
        XCTAssertEqual(requests.first?.modelOverride, "haiku")
        XCTAssertEqual(requests.first?.allowedToolsOverride, [])
        XCTAssertEqual(requests.first?.ephemeral, true)
        XCTAssertFalse(requests[0].prompt.contains("https://"), "Responses use opaque IDs; URLs are not required")
    }

    func testDisabledStageMakesNoRequestsAndSettingsReclassifyRetainedCards() async {
        let defaults = defaults()
        defaults.set(false, forKey: AppSettings.mrDispositionEnabledKey)
        var requests = 0
        var usedPrompt = ""
        let controller = MRReviewDispositionController(defaults: defaults, notificationCenter: NotificationCenter()) { invocation in
            requests += 1
            usedPrompt = invocation.prompt
            return try self.response(invocation)
        }
        defer { controller.shutdown() }
        controller.update([card()])
        await settle(controller)
        XCTAssertEqual(requests, 0)
        defaults.set("Custom classification rules", forKey: AppSettings.mrDispositionPromptKey)
        defaults.set(true, forKey: AppSettings.mrDispositionEnabledKey)
        controller.settingsChanged()
        await settle(controller)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(usedPrompt.hasPrefix("Custom classification rules"))
        XCTAssertTrue(usedPrompt.contains("Required output contract (unchangeable)"))
        defaults.set(false, forKey: AppSettings.mrDispositionEnabledKey)
        controller.settingsChanged()
        XCTAssertNil(controller.disposition(for: card()))
    }

    func testDisabledDuringRequestRejectsLateOutput() async throws {
        let defaults = defaults()
        var release: CheckedContinuation<ClaudeOperationOutput, Never>?
        var invocation: ClaudeOperationInvocation?
        let controller = MRReviewDispositionController(defaults: defaults, notificationCenter: NotificationCenter()) { request in
            invocation = request
            return await withCheckedContinuation { release = $0 }
        }
        defer { controller.shutdown() }
        controller.update([card()])
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(release)
        defaults.set(false, forKey: AppSettings.mrDispositionEnabledKey)
        controller.settingsChanged()
        if let invocation { release?.resume(returning: try response(invocation)) }
        await Task.yield()
        XCTAssertFalse(controller.isClassifying)
        XCTAssertNil(controller.disposition(for: card()))
    }

    func testResetRejectsOldSourceCompletion() async throws {
        var release: CheckedContinuation<ClaudeOperationOutput, Never>?
        var invocation: ClaudeOperationInvocation?
        let controller = MRReviewDispositionController(defaults: defaults(), notificationCenter: NotificationCenter()) { request in
            invocation = request
            return await withCheckedContinuation { release = $0 }
        }
        defer { controller.shutdown() }
        controller.update([card()])
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(2)) }
        controller.reset()
        if let invocation { release?.resume(returning: try response(invocation)) }
        await Task.yield()
        XCTAssertNil(controller.disposition(for: card()))
    }

    func testFailureRetainsDeterministicFallbackAndNeverDisplaysProviderError() async {
        let controller = MRReviewDispositionController(defaults: defaults(), notificationCenter: NotificationCenter()) { _ in
            throw ClaudeServiceError.executionFailed(reason: "SYNTHETIC_PRIVATE_ERROR_CONTENT")
        }
        defer { controller.shutdown() }
        controller.update([card()])
        await settle(controller)
        XCTAssertNil(controller.disposition(for: card()))
        XCTAssertTrue(controller.message?.contains("Showing GitLab states") == true)
        XCTAssertFalse(controller.message?.contains("SYNTHETIC_PRIVATE_ERROR_CONTENT") == true)
    }

    func testDecoderRejectsDuplicateMissingUnknownAndMismatchedResults() throws {
        let invocation = try MRDispositionPrompt.invocation(items: [card(0), card(1)], configuration: .load(defaults()))
        XCTAssertEqual(try MRDispositionPrompt.decode(response(invocation), correlationID: invocation.correlationID, count: 2), [.approved, .approved])
        for ids in [["mr-0", "mr-0"], ["mr-0"], ["mr-0", "invented"]] {
            XCTAssertThrowsError(try MRDispositionPrompt.decode(response(invocation, ids: ids), correlationID: invocation.correlationID, count: 2))
        }
        XCTAssertThrowsError(try MRDispositionPrompt.decode(response(invocation), correlationID: UUID(), count: 2))
        let invalid = ClaudeOperationOutput(correlationID: invocation.correlationID, resultText: "not JSON", sessionID: nil)
        XCTAssertThrowsError(try MRDispositionPrompt.decode(invalid, correlationID: invocation.correlationID, count: 2))
    }

    func testBlankPromptAndModelUseDefaults() {
        let defaults = defaults()
        defaults.set("  ", forKey: AppSettings.mrDispositionPromptKey)
        defaults.set("\n", forKey: AppSettings.mrScanModelKey)
        XCTAssertEqual(MRDispositionConfiguration.load(defaults).prompt, MRDispositionPrompt.defaultText)
        XCTAssertEqual(MRDispositionConfiguration.load(defaults).model, "haiku")
    }
}
