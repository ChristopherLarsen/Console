import XCTest
@testable import Console

@MainActor
final class AIProviderManagerLastRequestTests: XCTestCase {
    private var previousProviderRaw: String?

    override func setUp() {
        super.setUp()
        previousProviderRaw = UserDefaults.standard.string(forKey: "selectedAIProvider")
    }

    override func tearDown() {
        if let previousProviderRaw {
            UserDefaults.standard.set(previousProviderRaw, forKey: "selectedAIProvider")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedAIProvider")
        }
        super.tearDown()
    }

    func testLastRequestDefaultsToNone() {
        let manager = AIProviderManager()
        XCTAssertEqual(manager.lastRequest, .none)
    }

    func testRecordLastRequestSucceeded() {
        let manager = AIProviderManager()
        manager.selectedProvider = .openAI
        manager.recordLastRequest(success: true, for: .openAI)
        XCTAssertEqual(manager.lastRequest, .succeeded)
    }

    func testRecordLastRequestFailed() {
        let manager = AIProviderManager()
        manager.selectedProvider = .openAI
        manager.recordLastRequest(success: false, for: .openAI)
        XCTAssertEqual(manager.lastRequest, .failed)
    }

    func testOutcomeForOtherProviderDoesNotPaintSelection() {
        let manager = AIProviderManager()
        manager.selectedProvider = .openAI
        manager.recordLastRequest(success: true, for: .claude)
        XCTAssertEqual(manager.lastRequest, .none)

        manager.recordLastRequest(success: false, for: .gemini)
        XCTAssertEqual(manager.lastRequest, .none)
    }

    func testChangingSelectedProviderResetsLastRequest() {
        let manager = AIProviderManager()
        manager.selectedProvider = .openAI
        manager.recordLastRequest(success: true, for: .openAI)
        XCTAssertEqual(manager.lastRequest, .succeeded)

        manager.selectedProvider = .lmStudio
        XCTAssertEqual(manager.lastRequest, .none)
    }

    func testPingSelectedLocalProviderNoopsWhenNotLMStudio() async {
        let manager = AIProviderManager()
        manager.selectedProvider = .openAI
        await manager.pingSelectedLocalProviderIfNeeded()
        XCTAssertEqual(manager.lastRequest, .none)
    }

    func testPingSelectedLocalProviderUpdatesLastRequestForLMStudio() async {
        let manager = AIProviderManager()
        manager.selectedProvider = .lmStudio
        XCTAssertEqual(manager.lastRequest, .none)

        await manager.pingSelectedLocalProviderIfNeeded()
        XCTAssertNotEqual(manager.lastRequest, .none)
    }

    func testDefaultOpenAIKeychainRefMatchesSavePath() {
        let manager = AIProviderManager()
        UserDefaults.standard.removeObject(forKey: "aiConfig-openAI")
        // Settings saves under "ai-provider-\(rawValue)"; the default config
        // must use the same account or a prefs wipe orphans the stored key.
        XCTAssertEqual(AIProviderConfig.defaultConfigs[.openAI]?.apiKeyKeychainRef, "ai-provider-openAI")
        XCTAssertEqual(manager.config(for: .openAI).apiKeyKeychainRef, "ai-provider-openAI")
    }
}
