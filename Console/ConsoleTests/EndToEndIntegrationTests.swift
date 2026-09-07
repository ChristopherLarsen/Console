import XCTest
import AVFoundation
@testable import Console

@available(macOS 26.0, *)
final class EndToEndIntegrationTests: XCTestCase {

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

    // MARK: - Scenario 1: Normal Command Flow

    @MainActor
    func testNormalCommandFlow_WakeWordThenCommand() async {
        let controller = AudioSessionController.shared
        let source = SyntheticTranscriptSource([
            (0.3, "console"),
            (0.6, "open"),
            (0.8, "safari")
        ])
        source.autoFinalizeDelay = 1.0

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        let wakeExpectation = expectation(description: "Wake word detected")
        let commandExpectation = expectation(description: "Command transcribed")

        var detectedWake: String?
        var transcribedCmd: String?

        mode.onWakeWordDetected = { word in
            detectedWake = word
            wakeExpectation.fulfill()
        }
        mode.onCommandTranscribed = { cmd in
            transcribedCmd = cmd
            commandExpectation.fulfill()
        }

        let success = await controller.requestMode(mode)
        XCTAssertTrue(success, "Command mode should activate via controller")
        XCTAssertTrue(controller.isEngineRunning, "Engine should be running")
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(controller.activeMode === mode)

        await fulfillment(of: [wakeExpectation, commandExpectation], timeout: 6.0)

        XCTAssertEqual(detectedWake, "console")
        XCTAssertEqual(transcribedCmd, "open safari")
        XCTAssertEqual(mode.phase, .idle, "Pipeline should restart in idle after command")
        XCTAssertTrue(mode.isActive, "Mode should remain active for next command")
        XCTAssertTrue(controller.isEngineRunning, "Single engine should still be running")

        await controller.releaseMode(mode)
        XCTAssertFalse(mode.isActive)
    }

    @MainActor
    func testNormalCommandFlow_EngineRemainsStableAcrossSessions() async {
        let controller = AudioSessionController.shared
        let source = SyntheticTranscriptSource([
            (0.2, "console"),
            (0.4, "commands")
        ])
        source.autoFinalizeDelay = 0.8

        let mode = CommandListeningMode(transcriptSource: source)
        mode.updateWakeWords(["console"])

        let cmdExpectation = expectation(description: "Command received")
        mode.onCommandTranscribed = { _ in cmdExpectation.fulfill() }

        await controller.requestMode(mode)
        XCTAssertTrue(controller.isEngineRunning)

        await fulfillment(of: [cmdExpectation], timeout: 5.0)

        // After command, mode stays active and engine keeps running
        XCTAssertTrue(controller.isEngineRunning)
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(controller.activeMode === mode)

        await controller.releaseMode(mode)
    }

    // MARK: - Scenario 2: Note Mode Transition

    @MainActor
    func testNoteModeTransition_SuspendsAndRestoresCommand() async {
        let controller = AudioSessionController.shared

        // Activate command mode with synthetic source (no real mic needed)
        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)
        commandMode.updateWakeWords(["console"])

        await controller.requestMode(commandMode)
        XCTAssertTrue(commandMode.isActive)
        XCTAssertTrue(controller.activeMode === commandMode)

        // Request note mode (exclusive) — should suspend command mode
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        let noteSuccess = await controller.requestMode(noteMode)

        XCTAssertTrue(noteSuccess, "Exclusive note mode should preempt primary command mode")
        XCTAssertFalse(commandMode.isActive, "Command mode should be deactivated (suspended)")
        XCTAssertTrue(noteMode.isActive, "Note mode should now be active")
        XCTAssertTrue(controller.activeMode === noteMode)
        XCTAssertTrue(controller.isEngineRunning, "Engine should keep running")

        // Simulate "done" by releasing note mode
        await controller.releaseMode(noteMode)

        XCTAssertFalse(noteMode.isActive, "Note mode should be deactivated")
        XCTAssertTrue(commandMode.isActive, "Command mode should be restored from suspension")
        XCTAssertTrue(controller.activeMode === commandMode)
        XCTAssertTrue(controller.isEngineRunning, "Engine remains running after restore")

        await controller.releaseMode(commandMode)
    }

    @MainActor
    func testNoteModeTransition_NoStaleStateAfterRestore() async {
        let controller = AudioSessionController.shared

        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)
        commandMode.updateWakeWords(["console"])

        await controller.requestMode(commandMode)

        // Transition to note mode and back
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        await controller.requestMode(noteMode)
        await controller.releaseMode(noteMode)

        // Command mode restored — verify clean state
        XCTAssertTrue(commandMode.isActive)
        XCTAssertEqual(commandMode.phase, .idle, "Restored command mode should be in idle")
        XCTAssertTrue(commandMode.fullTranscript.isEmpty, "Transcript should be clean after restore")
        XCTAssertNil(commandMode.detectedWord, "No stale wake word after restore")

        await controller.releaseMode(commandMode)
    }

    // MARK: - Scenario 3: Field Dictation Flow

    @MainActor
    func testFieldDictation_ActivatesAndReleasesCleanly() async {
        let controller = AudioSessionController.shared
        let fieldMode = FieldDictationMode()

        var textResult: String?
        var pauseDetected = false

        // Track that callbacks are working
        defer {
            _ = textResult
            _ = pauseDetected
        }
        fieldMode.onTextFinalized = { text in textResult = text }
        fieldMode.onPauseDetected = { pauseDetected = true }

        let success = await controller.requestMode(fieldMode)
        XCTAssertTrue(success)
        XCTAssertTrue(fieldMode.isActive)
        XCTAssertTrue(controller.isEngineRunning)

        // Unit tests never drive live Speech: deliver text synthetically so
        // the deactivate-commits-pending-text path is actually exercised.
        fieldMode.appendAccumulatedTextForTesting("synthetic dictation text")

        // Simulate pause by releasing mode
        await controller.releaseMode(fieldMode)

        XCTAssertFalse(fieldMode.isActive)
        XCTAssertNil(controller.activeMode)
        XCTAssertEqual(textResult, "synthetic dictation text", "Deactivate must commit pending text")
        XCTAssertFalse(pauseDetected, "No pause should be detected without speech input")
    }

    @MainActor
    func testFieldDictation_CommandReactivatesAfterFieldCompletes() async {
        let controller = AudioSessionController.shared

        // Start with command mode
        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)
        commandMode.updateWakeWords(["console"])

        await controller.requestMode(commandMode)
        XCTAssertTrue(commandMode.isActive)

        // Release command mode (simulating UI transition to creation view)
        await controller.releaseMode(commandMode)
        XCTAssertFalse(commandMode.isActive)
        XCTAssertNil(controller.activeMode)

        // Activate field dictation
        let fieldMode = FieldDictationMode()
        await controller.requestMode(fieldMode)
        XCTAssertTrue(fieldMode.isActive)

        // Release field mode (simulating text populated + pause)
        await controller.releaseMode(fieldMode)
        XCTAssertFalse(fieldMode.isActive)

        // Re-activate command mode
        let reactivated = await controller.requestMode(commandMode)
        XCTAssertTrue(reactivated)
        XCTAssertTrue(commandMode.isActive)
        XCTAssertTrue(controller.activeMode === commandMode)

        await controller.releaseMode(commandMode)
    }

    // MARK: - Scenario 4: Exclusive Mode Blocks Lower Priority

    @MainActor
    func testExclusiveModeBlocksHotkeyActivation() async {
        let controller = AudioSessionController.shared

        // Note mode is exclusive
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        await controller.requestMode(noteMode)
        XCTAssertTrue(noteMode.isActive)

        // Simulate hotkey requesting command mode (primary < exclusive)
        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)

        let denied = await controller.requestMode(commandMode)

        XCTAssertFalse(denied, "Primary mode should be denied while exclusive note mode is active")
        XCTAssertFalse(commandMode.isActive)
        XCTAssertTrue(noteMode.isActive, "Note mode should remain undisturbed")
        XCTAssertTrue(controller.activeMode === noteMode)

        await controller.releaseMode(noteMode)
    }

    @MainActor
    func testExclusiveFieldPreemptsExclusiveNote() async {
        let controller = AudioSessionController.shared

        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        await controller.requestMode(noteMode)
        XCTAssertTrue(noteMode.isActive)

        // Field (.exclusive) can preempt note (.exclusive) — equal priority allowed
        let fieldMode = FieldDictationMode()
        let success = await controller.requestMode(fieldMode)

        XCTAssertTrue(success, "Equal-priority exclusive mode should be allowed")
        XCTAssertTrue(fieldMode.isActive)
        XCTAssertFalse(noteMode.isActive)

        await controller.releaseMode(fieldMode)
    }

    // MARK: - Scenario 5: Rapid Mode Switching

    @MainActor
    func testRapidModeSwitching_NoLeakedModes() async {
        let controller = AudioSessionController.shared

        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)
        commandMode.updateWakeWords(["console"])

        // Start command mode
        await controller.requestMode(commandMode)
        XCTAssertTrue(commandMode.isActive)

        // Rapid: Note preempt → dismiss → Note preempt → dismiss
        for i in 0..<3 {
            let vm = NoteViewModel(aiProviderManager: AIProviderManager())
            let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

            let success = await controller.requestMode(noteMode)
            XCTAssertTrue(success, "Note mode \(i) should activate")
            XCTAssertTrue(noteMode.isActive)
            XCTAssertFalse(commandMode.isActive)

            await controller.releaseMode(noteMode)
            XCTAssertFalse(noteMode.isActive)
            XCTAssertTrue(commandMode.isActive, "Command mode should be restored after note \(i)")
        }

        // Final state: command mode is active, engine running, no leaked modes
        XCTAssertTrue(commandMode.isActive)
        XCTAssertTrue(controller.activeMode === commandMode)
        XCTAssertTrue(controller.isEngineRunning)

        await controller.releaseMode(commandMode)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
    }

    @MainActor
    func testRapidModeSwitching_NoStaleAudioLevels() async {
        let controller = AudioSessionController.shared

        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)

        await controller.requestMode(commandMode)

        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        await controller.requestMode(noteMode)
        await controller.releaseMode(noteMode)

        // After rapid transitions, shutdown should cleanly zero out audio
        await controller.shutdown()

        XCTAssertEqual(controller.currentAudioLevel, 0.0)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
    }

    // MARK: - Scenario 6: Permission Revocation (Simulated via Shutdown)

    @MainActor
    func testShutdownDuringCommandMode_CleansUp() async {
        let controller = AudioSessionController.shared

        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)
        commandMode.updateWakeWords(["console"])

        await controller.requestMode(commandMode)
        XCTAssertTrue(commandMode.isActive)
        XCTAssertTrue(controller.isEngineRunning)

        // Simulate permission revocation via shutdown
        await controller.shutdown()

        XCTAssertFalse(commandMode.isActive, "Active mode should be deactivated on shutdown")
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning, "Engine should stop on shutdown")
        XCTAssertEqual(controller.currentAudioLevel, 0.0)
    }

    @MainActor
    func testShutdownDuringNoteMode_CleansUp() async {
        let controller = AudioSessionController.shared

        let source = SyntheticTranscriptSource([])
        let commandMode = CommandListeningMode(transcriptSource: source)
        await controller.requestMode(commandMode)

        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let noteMode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())
        await controller.requestMode(noteMode)

        XCTAssertTrue(noteMode.isActive)
        XCTAssertFalse(commandMode.isActive)

        // Simulate permission revocation
        await controller.shutdown()

        XCTAssertFalse(noteMode.isActive)
        XCTAssertFalse(commandMode.isActive)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
    }

    @MainActor
    func testShutdownDuringFieldDictation_CleansUp() async {
        let controller = AudioSessionController.shared
        let fieldMode = FieldDictationMode()

        await controller.requestMode(fieldMode)
        XCTAssertTrue(fieldMode.isActive)

        await controller.shutdown()

        XCTAssertFalse(fieldMode.isActive)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
    }
}
