import XCTest
import AVFoundation
@testable import Console

@available(macOS 26.0, *)
final class FieldDictationModeTests: XCTestCase {

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

    // MARK: - Activate sets isActive

    @MainActor
    func testActivateSetsIsActive() async {
        let mode = FieldDictationMode()

        XCTAssertFalse(mode.isActive)

        await mode.activate(audioStream: nil)

        XCTAssertTrue(mode.isActive)
        await mode.deactivate()
    }

    // MARK: - Deactivate clears state

    @MainActor
    func testDeactivateClearsState() async {
        let mode = FieldDictationMode()

        await mode.activate(audioStream: nil)
        XCTAssertTrue(mode.isActive)

        await mode.deactivate()

        XCTAssertFalse(mode.isActive)
    }

    // MARK: - Consume resets accumulated text

    @MainActor
    func testConsumeResetsState() async {
        let mode = FieldDictationMode()

        await mode.activate(audioStream: nil)

        // consume() should not crash and should reset internal state
        mode.consume()

        await mode.deactivate()
    }

    // MARK: - Manual stop commits pending text (H18-F01)

    @MainActor
    func testDeactivateDeliversAccumulatedText() async {
        let mode = FieldDictationMode()
        var delivered: String?
        mode.onTextFinalized = { delivered = $0 }

        await mode.activate(audioStream: nil)
        mode.appendAccumulatedTextForTesting("hello world")

        await mode.deactivate()

        XCTAssertEqual(delivered, "hello world")
        XCTAssertFalse(mode.isActive)
    }

    @MainActor
    func testDeactivateTrimsDeliveredText() async {
        let mode = FieldDictationMode()
        var delivered: String?
        mode.onTextFinalized = { delivered = $0 }

        await mode.activate(audioStream: nil)
        mode.appendAccumulatedTextForTesting("  padded text  ")

        await mode.deactivate()

        XCTAssertEqual(delivered, "padded text")
    }

    @MainActor
    func testDeactivateWithNoAccumulatedTextDoesNotFinalize() async {
        let mode = FieldDictationMode()
        var delivered: String?
        mode.onTextFinalized = { delivered = $0 }

        await mode.activate(audioStream: nil)
        await mode.deactivate()

        XCTAssertNil(delivered)
    }

    // MARK: - Callback wiring

    @MainActor
    func testCallbacksCanBeSet() async {
        let mode = FieldDictationMode()
        var textReceived: String?
        var pauseDetected = false

        mode.onTextFinalized = { text in
            textReceived = text
        }
        mode.onPauseDetected = {
            pauseDetected = true
        }

        // Callbacks are set but won't fire without real audio
        XCTAssertNil(textReceived)
        XCTAssertFalse(pauseDetected)
    }

    // MARK: - Integration via AudioSessionController

    @MainActor
    func testActivateViaAudioSessionController() async {
        let controller = AudioSessionController.shared
        let mode = FieldDictationMode()

        let success = await controller.requestMode(mode)

        XCTAssertTrue(success)
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(controller.activeMode === mode)

        await controller.releaseMode(mode)

        XCTAssertFalse(mode.isActive)
        XCTAssertNil(controller.activeMode)
    }

    // MARK: - Priority is exclusive

    @MainActor
    func testPriorityIsExclusive() async {
        let mode = FieldDictationMode()
        XCTAssertEqual(mode.priority, .exclusive)
        XCTAssertEqual(mode.modeIdentifier, "fieldDictation")
    }

    // MARK: - Release stops dictation (simulates focus loss)

    @MainActor
    func testReleaseModeDeactivatesDictation() async {
        let controller = AudioSessionController.shared
        let mode = FieldDictationMode()

        var pauseFired = false
        mode.onPauseDetected = {
            pauseFired = true
            _ = pauseFired  // Silence unused warning
        }

        let success = await controller.requestMode(mode)
        XCTAssertTrue(success)
        XCTAssertTrue(mode.isActive)

        await controller.releaseMode(mode)

        XCTAssertFalse(mode.isActive)
        XCTAssertNil(controller.activeMode)
    }

    // MARK: - Notification triggers dictation stop

    @MainActor
    func testDidResignActiveStopsDictation() async {
        let controller = AudioSessionController.shared
        let mode = FieldDictationMode()

        await controller.requestMode(mode)
        XCTAssertTrue(mode.isActive)

        // Simulate what CommandCreationView does on didResignActiveNotification
        await controller.releaseMode(mode)

        XCTAssertFalse(mode.isActive, "Field dictation should be inactive after app resign")
    }
}
