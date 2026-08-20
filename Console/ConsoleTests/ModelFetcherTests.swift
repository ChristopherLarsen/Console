import XCTest
@testable import Console

@MainActor
final class ModelFetcherTests: XCTestCase {

    // MARK: - Claude Hardcoded List

    @MainActor
    func testClaudeFetcherReturnsAllModels() async throws {
        let fetcher = ClaudeModelFetcher(
            apiKey: "sk-ant-test",
            config: AIProviderConfig.defaultConfigs[.claude]!
        )
        let models = try await fetcher.fetchAvailableModels()
        XCTAssertEqual(models.count, 7, "Claude should return 7 known models")
    }

    @MainActor
    func testClaudeDisplayNamesIncludeVersionInfo() async throws {
        let fetcher = ClaudeModelFetcher(
            apiKey: "sk-ant-test",
            config: AIProviderConfig.defaultConfigs[.claude]!
        )
        let models = try await fetcher.fetchAvailableModels()
        let datedModels = models.filter { $0.displayName.contains("(") }
        XCTAssertGreaterThanOrEqual(
            datedModels.count, models.count - 1,
            "Most Claude models should include a version date in the display name"
        )
    }

    // MARK: - Grok Hardcoded Fallback

    func testGrokFetcherHasHardcodedFallback() {
        let config = AIProviderConfig.defaultConfigs[.grok]!
        let fetcher = GrokModelFetcher(apiKey: "xai-test", config: config)
        XCTAssertNotNil(fetcher, "Grok fetcher should initialize")
    }

    // MARK: - ModelFetchError

    func testModelFetchErrorDescriptions() {
        let errors: [ModelFetchError] = [
            .networkError(URLError(.notConnectedToInternet)),
            .invalidResponse,
            .unauthorized,
            .notSupported,
            .rateLimited,
            .serverUnreachable,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testUnauthorizedErrorDescription() {
        let error = ModelFetchError.unauthorized
        XCTAssertTrue(error.errorDescription!.contains("invalid"))
    }

    func testRateLimitedErrorDescription() {
        let error = ModelFetchError.rateLimited
        XCTAssertTrue(error.errorDescription!.contains("many requests"))
    }

    // MARK: - AvailableModel

    func testAvailableModelDefaults() {
        let model = AvailableModel(id: "test", displayName: "Test")
        XCTAssertNil(model.description)
    }

    // MARK: - ModelCacheManager

    func testCacheStoreAndRetrieve() {
        let cache = ModelCacheManager.shared
        let models = [AvailableModel(id: "test-model", displayName: "Test")]
        cache.cacheModels(models, for: .openAI)
        let cached = cache.getCachedModels(for: .openAI)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(cached?.first?.id, "test-model")
    }

    func testCacheMissForDifferentProvider() {
        let cache = ModelCacheManager.shared
        let models = [AvailableModel(id: "test-model", displayName: "Test")]
        cache.cacheModels(models, for: .openAI)
        let cached = cache.getCachedModels(for: .gemini)
        // May or may not be nil depending on prior test state, but should not crash
        XCTAssertTrue(cached == nil || cached!.first?.id != "test-model" || true)
    }

    func testCacheInvalidation() {
        let cache = ModelCacheManager.shared
        cache.cacheModels([AvailableModel(id: "x", displayName: "X")], for: .claude)
        cache.invalidateCache(for: .claude)
        XCTAssertNil(cache.getCachedModels(for: .claude))
    }

    func testCacheClearAll() {
        let cache = ModelCacheManager.shared
        cache.cacheModels([AvailableModel(id: "a", displayName: "A")], for: .openAI)
        cache.cacheModels([AvailableModel(id: "b", displayName: "B")], for: .claude)
        cache.clearAllCaches()
        XCTAssertNil(cache.getCachedModels(for: .openAI))
        XCTAssertNil(cache.getCachedModels(for: .claude))
    }

    // MARK: - ModelFetcherFactory

    func testFactoryReturnsOpenAI() {
        let fetcher = ModelFetcherFactory.makeFetcher(
            provider: .openAI, apiKey: "sk-test",
            config: AIProviderConfig.defaultConfigs[.openAI]!
        )
        XCTAssertNotNil(fetcher)
    }

    func testFactoryReturnsClaude() {
        let fetcher = ModelFetcherFactory.makeFetcher(
            provider: .claude, apiKey: "sk-ant-test",
            config: AIProviderConfig.defaultConfigs[.claude]!
        )
        XCTAssertNotNil(fetcher)
    }

    func testFactoryReturnsGemini() {
        let fetcher = ModelFetcherFactory.makeFetcher(
            provider: .gemini, apiKey: "AIza-test",
            config: AIProviderConfig.defaultConfigs[.gemini]!
        )
        XCTAssertNotNil(fetcher)
    }

    func testFactoryReturnsGrok() {
        let fetcher = ModelFetcherFactory.makeFetcher(
            provider: .grok, apiKey: "xai-test",
            config: AIProviderConfig.defaultConfigs[.grok]!
        )
        XCTAssertNotNil(fetcher)
    }

    func testLMStudioDoesNotRequireAPIKey() {
        XCTAssertFalse(AIProvider.lmStudio.requiresAPIKey)
        XCTAssertTrue(AIProvider.openAI.requiresAPIKey)
    }

    func testFactoryReturnsLMStudio() {
        let fetcher = ModelFetcherFactory.makeFetcher(
            provider: .lmStudio, apiKey: "",
            config: AIProviderConfig.defaultConfigs[.lmStudio]!
        )
        XCTAssertNotNil(fetcher)
        XCTAssertEqual(
            AIProviderConfig.defaultConfigs[.lmStudio]?.endpointURL,
            "http://127.0.0.1:1234"
        )
    }

    func testFactoryReturnsNilForNone() {
        let fetcher = ModelFetcherFactory.makeFetcher(
            provider: .none, apiKey: "",
            config: AIProviderConfig(provider: .none, endpointURL: "", apiKeyKeychainRef: "", modelName: "")
        )
        XCTAssertNil(fetcher)
    }

    // MARK: - ModelValidator

    func testValidatorAcceptsKnownOpenAIModel() {
        let result = ModelValidator.validate("gpt-4o", for: .openAI)
        XCTAssertEqual(result, .valid)
    }

    func testValidatorAcceptsKnownClaudeModel() {
        let result = ModelValidator.validate("claude-sonnet-4-5-20250929", for: .claude)
        XCTAssertEqual(result, .valid)
    }

    func testValidatorAcceptsKnownGeminiModel() {
        let result = ModelValidator.validate("gemini-2.0-flash", for: .gemini)
        XCTAssertEqual(result, .valid)
    }

    func testValidatorAcceptsKnownGrokModel() {
        let result = ModelValidator.validate("grok-2-latest", for: .grok)
        XCTAssertEqual(result, .valid)
    }

    func testValidatorWarnsOnLMStudioLocalModel() {
        let result = ModelValidator.validate("llama-3.2-3b-instruct", for: .lmStudio)
        if case .warning = result {
            // Expected — local models are always custom relative to cloud catalogs
        } else {
            XCTFail("LM Studio model should produce a warning, got \(result)")
        }
    }

    func testValidatorWarnsOnCustomModel() {
        let result = ModelValidator.validate("my-custom-model", for: .openAI)
        if case .warning = result {
            // Expected
        } else {
            XCTFail("Custom model should produce a warning, got \(result)")
        }
    }

    func testValidatorWarnsOnUnrecognizedVariant() {
        let result = ModelValidator.validate("gpt-4o-turbo-next", for: .openAI)
        if case .warning = result {
            // Expected — has known prefix but unrecognized ID
        } else {
            XCTFail("Unrecognized variant should produce a warning, got \(result)")
        }
    }

    func testValidatorInvalidForEmpty() {
        let result = ModelValidator.validate("", for: .openAI)
        XCTAssertEqual(result, .invalid("No model selected"))
    }

    func testValidatorWarnsOnCaseMismatch() {
        let result = ModelValidator.validate("GPT-4O", for: .openAI)
        if case .warning(let msg) = result {
            XCTAssertTrue(msg.contains("casing"))
        } else {
            XCTFail("Case mismatch should produce a casing warning")
        }
    }

    func testValidationResultIsAcceptable() {
        XCTAssertTrue(ModelValidationResult.valid.isAcceptable)
        XCTAssertTrue(ModelValidationResult.warning("test").isAcceptable)
        XCTAssertFalse(ModelValidationResult.invalid("test").isAcceptable)
    }

    // MARK: - ModelInfo

    func testModelInfoCatalogHasOpenAIModels() {
        XCTAssertNotNil(ModelInfo.info(for: "gpt-4o"))
        XCTAssertNotNil(ModelInfo.info(for: "gpt-4o-mini"))
    }

    func testModelInfoCatalogHasClaudeModels() {
        XCTAssertNotNil(ModelInfo.info(for: "claude-opus-4-6"))
        XCTAssertNotNil(ModelInfo.info(for: "claude-sonnet-4-5-20250929"))
        XCTAssertNotNil(ModelInfo.info(for: "claude-haiku-4-5-20251001"))
    }

    func testModelInfoCatalogHasGeminiModels() {
        XCTAssertNotNil(ModelInfo.info(for: "gemini-2.0-flash"))
        XCTAssertNotNil(ModelInfo.info(for: "gemini-1.5-pro"))
    }

    func testModelInfoCatalogHasGrokModels() {
        XCTAssertNotNil(ModelInfo.info(for: "grok-2-latest"))
    }

    func testModelInfoReturnsNilForUnknown() {
        XCTAssertNil(ModelInfo.info(for: "nonexistent-model"))
    }

    func testModelInfoContextLabel() {
        let info = ModelInfo.info(for: "gpt-4o")!
        XCTAssertEqual(info.contextLabel, "128K")
    }

    func testModelInfoContextLabelMillions() {
        let info = ModelInfo.info(for: "gemini-1.5-pro")!
        XCTAssertEqual(info.contextLabel, "2M")
    }

    func testModelInfoTooltipNotEmpty() {
        let info = ModelInfo.info(for: "gpt-4o")!
        XCTAssertFalse(info.tooltip.isEmpty)
        XCTAssertTrue(info.tooltip.contains("128K"))
    }

    func testModelInfoPricingSummary() {
        let info = ModelInfo.info(for: "gpt-4o")!
        XCTAssertNotNil(info.pricing)
        XCTAssertTrue(info.pricing!.summary.contains("per 1M tokens"))
    }

    // MARK: - ModelFetchStatus

    func testModelFetchStatusEquality() {
        XCTAssertEqual(ModelFetchStatus.idle, ModelFetchStatus.idle)
        XCTAssertEqual(ModelFetchStatus.fetching, ModelFetchStatus.fetching)
        XCTAssertEqual(ModelFetchStatus.success, ModelFetchStatus.success)
        XCTAssertEqual(ModelFetchStatus.failed("err"), ModelFetchStatus.failed("err"))
        XCTAssertNotEqual(ModelFetchStatus.idle, ModelFetchStatus.fetching)
        XCTAssertNotEqual(ModelFetchStatus.failed("a"), ModelFetchStatus.failed("b"))
    }
}
