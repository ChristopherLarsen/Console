import XCTest
import AVFoundation
@testable import Console

// MARK: - Mock Listening Modes

@MainActor
private final class MockMode: ListeningMode {
    let modeIdentifier: String
    let priority: ModePriority
    private(set) var isActive = false
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0

    init(identifier: String, priority: ModePriority) {
        self.modeIdentifier = identifier
        self.priority = priority
    }

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        activateCount += 1
    }

    func deactivate() async {
        isActive = false
        deactivateCount += 1
    }
}

// MARK: - Tests

final class AudioSessionControllerTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        AudioSessionController._unitTestMode = true
        await AudioSessionController.shared.shutdown()
    }

    @MainActor
    override func tearDown() async throws {
        await AudioSessionController.shared.shutdown()
        AudioSessionController._unitTestMode = false
    }

    // MARK: - requestMode with no active mode

    @MainActor
    func testRequestModeWithNoActiveMode() async {
        let controller = AudioSessionController.shared
        let mode = MockMode(identifier: "test", priority: .primary)

        let success = await controller.requestMode(mode)

        XCTAssertTrue(success)
        XCTAssertTrue(mode.isActive)
        XCTAssertEqual(mode.activateCount, 1)
        XCTAssertTrue(controller.activeMode === mode)
    }

    // MARK: - requestMode: higher priority preempts lower

    @MainActor
    func testHigherPriorityPreemptsLower() async {
        let controller = AudioSessionController.shared
        let normalMode = MockMode(identifier: "normal", priority: .normal)
        let primaryMode = MockMode(identifier: "primary", priority: .primary)

        await controller.requestMode(normalMode)
        XCTAssertTrue(controller.activeMode === normalMode)

        let success = await controller.requestMode(primaryMode)

        XCTAssertTrue(success)
        XCTAssertFalse(normalMode.isActive)
        XCTAssertEqual(normalMode.deactivateCount, 1)
        XCTAssertTrue(primaryMode.isActive)
        XCTAssertTrue(controller.activeMode === primaryMode)
    }

    // MARK: - requestMode: lower priority denied

    @MainActor
    func testLowerPriorityDenied() async {
        let controller = AudioSessionController.shared
        let primaryMode = MockMode(identifier: "primary", priority: .primary)
        let normalMode = MockMode(identifier: "normal", priority: .normal)

        await controller.requestMode(primaryMode)

        let success = await controller.requestMode(normalMode)

        XCTAssertFalse(success)
        XCTAssertFalse(normalMode.isActive)
        XCTAssertEqual(normalMode.activateCount, 0)
        XCTAssertTrue(controller.activeMode === primaryMode)
    }

    // MARK: - requestMode: exclusive suspends primary

    @MainActor
    func testExclusiveSuspendsPrimary() async {
        let controller = AudioSessionController.shared
        let primaryMode = MockMode(identifier: "primary", priority: .primary)
        let exclusiveMode = MockMode(identifier: "exclusive", priority: .exclusive)

        await controller.requestMode(primaryMode)
        XCTAssertTrue(primaryMode.isActive)

        let success = await controller.requestMode(exclusiveMode)

        XCTAssertTrue(success)
        XCTAssertFalse(primaryMode.isActive)
        XCTAssertTrue(exclusiveMode.isActive)
        XCTAssertTrue(controller.activeMode === exclusiveMode)
    }

    // MARK: - releaseMode restores suspended mode

    @MainActor
    func testReleaseModeRestoresSuspended() async {
        let controller = AudioSessionController.shared
        let primaryMode = MockMode(identifier: "primary", priority: .primary)
        let exclusiveMode = MockMode(identifier: "exclusive", priority: .exclusive)

        await controller.requestMode(primaryMode)
        await controller.requestMode(exclusiveMode)

        // Release exclusive — primary should be restored
        await controller.releaseMode(exclusiveMode)

        XCTAssertFalse(exclusiveMode.isActive)
        XCTAssertTrue(primaryMode.isActive)
        XCTAssertEqual(primaryMode.activateCount, 2)
        XCTAssertTrue(controller.activeMode === primaryMode)
    }

    // MARK: - releaseMode with no suspended mode

    @MainActor
    func testReleaseModeNoSuspendedStopsEngine() async {
        let controller = AudioSessionController.shared
        let mode = MockMode(identifier: "test", priority: .primary)

        await controller.requestMode(mode)
        await controller.releaseMode(mode)

        XCTAssertFalse(mode.isActive)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
    }

    // MARK: - releaseMode with wrong mode is no-op

    @MainActor
    func testReleaseModeWithWrongModeIsNoOp() async {
        let controller = AudioSessionController.shared
        let activeMode = MockMode(identifier: "active", priority: .primary)
        let wrongMode = MockMode(identifier: "wrong", priority: .normal)

        await controller.requestMode(activeMode)
        await controller.releaseMode(wrongMode)

        XCTAssertTrue(activeMode.isActive)
        XCTAssertTrue(controller.activeMode === activeMode)
        XCTAssertEqual(activeMode.deactivateCount, 0)
    }

    // MARK: - prewarmEngine

    @MainActor
    func testPrewarmEngine() {
        let controller = AudioSessionController.shared
        controller.prewarmEngine()

        XCTAssertTrue(controller.isEngineRunning)
    }

    // MARK: - shutdown

    @MainActor
    func testShutdownCleansUpAllState() async {
        let controller = AudioSessionController.shared
        let mode = MockMode(identifier: "test", priority: .primary)

        await controller.requestMode(mode)
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(controller.isEngineRunning)

        await controller.shutdown()

        XCTAssertFalse(mode.isActive)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
        XCTAssertEqual(controller.currentAudioLevel, 0.0)
    }
}
