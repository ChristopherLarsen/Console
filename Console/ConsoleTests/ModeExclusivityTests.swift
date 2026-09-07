import XCTest
import AVFoundation
@testable import Console

// Mock modes matching real app priority levels

@MainActor
private final class MockCommandMode: ListeningMode {
    let modeIdentifier = "command"
    let priority: ModePriority = .primary
    private(set) var isActive = false
    private(set) var activateCount = 0

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async {
        isActive = true
        activateCount += 1
    }
    func deactivate() async { isActive = false }
}

@MainActor
private final class MockNoteMode: ListeningMode {
    let modeIdentifier = "noteDictation"
    let priority: ModePriority = .exclusive
    private(set) var isActive = false

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async { isActive = true }
    func deactivate() async { isActive = false }
}

@MainActor
private final class MockFieldMode: ListeningMode {
    let modeIdentifier = "fieldDictation"
    let priority: ModePriority = .exclusive
    private(set) var isActive = false

    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async { isActive = true }
    func deactivate() async { isActive = false }
}

// MARK: - Tests

final class ModeExclusivityTests: XCTestCase {

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

    // MARK: - Command active → Note requested → Command suspended

    @MainActor
    func testNotePreemptsAndSuspendsCommand() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let note = MockNoteMode()

        await controller.requestMode(command)
        XCTAssertTrue(command.isActive)

        let success = await controller.requestMode(note)

        XCTAssertTrue(success)
        XCTAssertFalse(command.isActive)
        XCTAssertTrue(note.isActive)
        XCTAssertTrue(controller.activeMode === note)
    }

    // MARK: - Note released → Command restored

    @MainActor
    func testReleaseNoteRestoresCommand() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let note = MockNoteMode()

        await controller.requestMode(command)
        await controller.requestMode(note)

        await controller.releaseMode(note)

        XCTAssertFalse(note.isActive)
        XCTAssertTrue(command.isActive)
        XCTAssertEqual(command.activateCount, 2)
        XCTAssertTrue(controller.activeMode === command)
    }

    // MARK: - Note active → Field preempts (both exclusive, equal priority)

    @MainActor
    func testFieldPreemptsNoteWhenBothExclusive() async {
        let controller = AudioSessionController.shared
        let note = MockNoteMode()
        let field = MockFieldMode()

        await controller.requestMode(note)

        let success = await controller.requestMode(field)

        XCTAssertTrue(success)
        XCTAssertFalse(note.isActive)
        XCTAssertTrue(field.isActive)
        XCTAssertTrue(controller.activeMode === field)
    }

    // MARK: - Command active → Field preempts → Command suspended

    @MainActor
    func testFieldPreemptsAndSuspendsCommand() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let field = MockFieldMode()

        await controller.requestMode(command)

        let success = await controller.requestMode(field)

        XCTAssertTrue(success)
        XCTAssertFalse(command.isActive)
        XCTAssertTrue(field.isActive)
        XCTAssertTrue(controller.activeMode === field)
    }

    // MARK: - Field released → Command restored

    @MainActor
    func testFieldReleasedRestoresCommand() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let field = MockFieldMode()

        await controller.requestMode(command)
        await controller.requestMode(field)

        await controller.releaseMode(field)

        XCTAssertFalse(field.isActive)
        XCTAssertTrue(command.isActive)
        XCTAssertEqual(command.activateCount, 2)
        XCTAssertTrue(controller.activeMode === command)
    }

    // MARK: - H18-F05: exclusive field dictation suspends and resumes note dictation

    @MainActor
    func testFieldDictationSuspendsAndResumesNoteDictation() async {
        let controller = AudioSessionController.shared
        let note = MockNoteMode()
        let field = MockFieldMode()

        await controller.requestMode(note)
        let success = await controller.requestMode(field)

        XCTAssertTrue(success)
        XCTAssertTrue(controller.activeMode === field)
        XCTAssertEqual(controller.suspendedModes.last?.modeIdentifier, "noteDictation")

        await controller.releaseMode(field)

        XCTAssertFalse(field.isActive)
        XCTAssertTrue(note.isActive)
        XCTAssertTrue(controller.activeMode === note)
    }

    // MARK: - Suspended modes restore in reverse suspension order

    @MainActor
    func testSuspendedStackRestoresInReverseOrder() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let note = MockNoteMode()
        let field = MockFieldMode()

        await controller.requestMode(command)   // primary
        await controller.requestMode(note)      // exclusive suspends command
        await controller.requestMode(field)     // exclusive suspends note

        await controller.releaseMode(field)
        XCTAssertTrue(controller.activeMode === note)
        XCTAssertTrue(note.isActive)

        await controller.releaseMode(note)
        XCTAssertTrue(controller.activeMode === command)
        XCTAssertTrue(command.isActive)
        XCTAssertTrue(controller.suspendedModes.isEmpty)
    }

    // MARK: - Discarding a suspended mode prevents its restoration

    @MainActor
    func testDiscardSuspendedModePreventsRestore() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let field = MockFieldMode()

        await controller.requestMode(command)
        await controller.requestMode(field)

        await controller.discardSuspendedMode(command)
        await controller.releaseMode(field)

        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(command.isActive)
        XCTAssertFalse(controller.isEngineRunning)
    }

    // MARK: - No mode → Command → release → clean state

    @MainActor
    func testCommandRequestAndReleaseCleanState() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()

        await controller.requestMode(command)
        XCTAssertTrue(command.isActive)

        await controller.releaseMode(command)

        XCTAssertFalse(command.isActive)
        XCTAssertNil(controller.activeMode)
        XCTAssertFalse(controller.isEngineRunning)
    }

    // MARK: - Rapid transitions: Command → Note → release → Note → release → Command restored

    @MainActor
    func testRapidTransitionsNoLeakedState() async {
        let controller = AudioSessionController.shared
        let command = MockCommandMode()
        let note1 = MockNoteMode()
        let note2 = MockNoteMode()

        // Start with command
        await controller.requestMode(command)
        XCTAssertTrue(command.isActive)

        // Note preempts, command suspended
        await controller.requestMode(note1)
        XCTAssertTrue(note1.isActive)
        XCTAssertFalse(command.isActive)

        // Release note → command restored
        await controller.releaseMode(note1)
        XCTAssertFalse(note1.isActive)
        XCTAssertTrue(command.isActive)
        XCTAssertEqual(command.activateCount, 2)

        // Another note preempts again
        await controller.requestMode(note2)
        XCTAssertTrue(note2.isActive)
        XCTAssertFalse(command.isActive)

        // Release second note → command restored again
        await controller.releaseMode(note2)
        XCTAssertFalse(note2.isActive)
        XCTAssertTrue(command.isActive)
        XCTAssertEqual(command.activateCount, 3)
        XCTAssertTrue(controller.activeMode === command)
    }
}
