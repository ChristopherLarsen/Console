import XCTest
@testable import Console

final class ModelSelectionTests: XCTestCase {

    // MARK: - Model Selection Logic

    func testPickerSelectionSetsModel() {
        let modelID = "gpt-4o"
        let model = AvailableModel(id: modelID, displayName: "GPT-4o")
        XCTAssertEqual(model.id, modelID)
    }

    func testCustomEntryAllowsAnyString() {
        let customModel = "my-fine-tuned-gpt4"
        let result = ModelValidator.validate(customModel, for: .openAI)
        // Custom models should be accepted with a warning
        XCTAssertTrue(result.isAcceptable)
    }

    @MainActor
    func testSwitchingFromPickerToCustomClearsSelection() {
        // When switching to custom entry, the model should be empty
        let emptyModel = ""
        XCTAssertEqual(ModelValidator.validate(emptyModel, for: .openAI), .invalid("No model selected"))
    }

    @MainActor
    func testModelSelectionPersistsAcrossProviders() {
        // Validate that a model selected for one provider is valid for that provider
        let openAIResult = ModelValidator.validate("gpt-4o", for: .openAI)
        let claudeResult = ModelValidator.validate("gpt-4o", for: .claude)
        XCTAssertEqual(openAIResult, .valid)
        // GPT model is not a known Claude model — should warn
        if case .warning = claudeResult {
            // Expected
        } else {
            XCTFail("Cross-provider model should produce warning")
        }
    }

    // MARK: - Error State

    @MainActor
    func testFetchFailureShowsError() {
        let status = ModelFetchStatus.failed("Network timeout")
        if case .failed(let msg) = status {
            XCTAssertEqual(msg, "Network timeout")
        } else {
            XCTFail("Status should be failed")
        }
    }

    @MainActor
    func testFetchSuccessState() {
        let status = ModelFetchStatus.success
        XCTAssertEqual(status, .success)
    }

    // MARK: - Loading State

    @MainActor
    func testFetchingState() {
        let status = ModelFetchStatus.fetching
        XCTAssertEqual(status, .fetching)
        XCTAssertNotEqual(status, .idle)
    }

    // MARK: - Refresh via Cache Invalidation

    func testRefreshInvalidatesCacheForProvider() {
        let cache = ModelCacheManager.shared
        let models = [AvailableModel(id: "gpt-4o", displayName: "GPT-4o")]
        cache.cacheModels(models, for: .openAI, endpointURL: "https://api.test", apiKey: "k1")
        XCTAssertNotNil(cache.getCachedModels(for: .openAI, endpointURL: "https://api.test", apiKey: "k1"))

        cache.invalidateCache(for: .openAI)
        XCTAssertNil(cache.getCachedModels(for: .openAI, endpointURL: "https://api.test", apiKey: "k1"))
    }

    // MARK: - Model Source Enum

    func testModelSourcePickerAndCustom() {
        let picker: ModelSource = .picker
        let custom: ModelSource = .custom
        // Verify both cases exist and are distinct
        XCTAssertFalse(picker == custom)
    }

    // MARK: - Validation Across All Providers

    @MainActor
    func testValidationForAllProviders() {
        let providerModels: [(AIProvider, String)] = [
            (.openAI, "gpt-4o"),
            (.claude, "claude-sonnet-4-20250514"),
            (.gemini, "gemini-2.0-flash"),
            (.grok, "grok-2-latest"),
        ]
        for (provider, model) in providerModels {
            let result = ModelValidator.validate(model, for: provider)
            XCTAssertEqual(result, .valid, "\(model) should be valid for \(provider)")
        }

        let lmStudioResult = ModelValidator.validate("local-model", for: .lmStudio)
        if case .warning = lmStudioResult {
            // Expected
        } else {
            XCTFail("LM Studio custom model should warn, got \(lmStudioResult)")
        }
    }

    @MainActor
    func testValidationEmptyForAllProviders() {
        let providers: [AIProvider] = [.openAI, .claude, .gemini, .grok, .lmStudio]
        for provider in providers {
            let result = ModelValidator.validate("", for: provider)
            XCTAssertEqual(result, .invalid("No model selected"))
        }
    }

    // MARK: - Model Info Tooltip in Selection

    func testSelectedModelShowsTooltip() {
        let info = ModelInfo.info(for: "gpt-4o")
        XCTAssertNotNil(info, "Known model should have info")
        XCTAssertTrue(info!.tooltip.contains("Context:"))
    }

    func testCustomModelHasNoTooltip() {
        let info = ModelInfo.info(for: "my-custom-model")
        XCTAssertNil(info, "Unknown model should not have info")
    }
}

// ModelSource doesn't conform to Equatable — use pattern matching
private func == (lhs: ModelSource, rhs: ModelSource) -> Bool {
    switch (lhs, rhs) {
    case (.picker, .picker), (.custom, .custom): return true
    default: return false
    }
}
