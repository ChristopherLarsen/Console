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
        manager.recordLastRequest(success: true)
        XCTAssertEqual(manager.lastRequest, .succeeded)
    }

    func testRecordLastRequestFailed() {
        let manager = AIProviderManager()
        manager.recordLastRequest(success: false)
        XCTAssertEqual(manager.lastRequest, .failed)
    }

    func testChangingSelectedProviderResetsLastRequest() {
        let manager = AIProviderManager()
        manager.selectedProvider = .openAI
        manager.recordLastRequest(success: true)
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
}
