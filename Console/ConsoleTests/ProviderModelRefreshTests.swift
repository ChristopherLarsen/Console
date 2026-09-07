import XCTest
@testable import Console

final class ProviderModelRefreshTests: XCTestCase {

    // MARK: - H15-F02: failed LM Studio reconnect must clear stale models

    func testFailedReconnectClearsModelsAndFailsStatus() {
        let state = AIProviderConfigSection.refreshStateAfterReconnect(
            connectionResult: .networkError("connection refused"),
            previousModels: [AvailableModel(id: "qwen-2", displayName: "Qwen 2")]
        )
        XCTAssertFalse(state.shouldFetch)
        XCTAssertTrue(state.models.isEmpty, "stale model list must be dropped")
        if case .failed = state.status {} else {
            XCTFail("fetch status must not remain success after a failed reconnect")
        }
    }

    func testSuccessfulReconnectProceedsToFetch() {
        let previous = [AvailableModel(id: "qwen-2", displayName: "Qwen 2")]
        let state = AIProviderConfigSection.refreshStateAfterReconnect(
            connectionResult: .success,
            previousModels: previous
        )
        XCTAssertTrue(state.shouldFetch)
        XCTAssertEqual(state.models.map(\.id), previous.map(\.id))
    }

    // MARK: - H15-F03: Gemini fetch must honor the configured endpoint

    func testGeminiModelListUsesConfiguredEndpoint() throws {
        let custom = "https://gemini-proxy.example.test/v1beta/models"
        let url = try XCTUnwrap(GeminiModelFetcher.modelsURL(endpointURL: custom, apiKey: "k"))
        XCTAssertEqual(url.host, "gemini-proxy.example.test", "custom endpoint must be used")
        XCTAssertTrue(url.absoluteString.hasSuffix("/v1beta/models?key=k"))
    }

    func testGeminiDefaultEndpointStillWorks() throws {
        let url = try XCTUnwrap(
            GeminiModelFetcher.modelsURL(
                endpointURL: AIProviderConfig.defaultConfigs[.gemini]!.endpointURL,
                apiKey: "k"
            )
        )
        XCTAssertEqual(url.host, "generativelanguage.googleapis.com")
    }

    // MARK: - H15-F04: validation warnings must be presentable

    func testValidationPresentationSurfacesWarnings() {
        let result = ModelValidator.validate("my-custom-model", for: .openAI)
        let presentation = ModelSelectionView.validationPresentation(for: result)
        XCTAssertNotNil(presentation, "warning must be visible")
        XCTAssertEqual(presentation?.isError, false)

        let invalid = ModelSelectionView.validationPresentation(
            for: .invalid("No model selected")
        )
        XCTAssertEqual(invalid?.isError, true)

        XCTAssertNil(ModelSelectionView.validationPresentation(for: .valid))
    }
}