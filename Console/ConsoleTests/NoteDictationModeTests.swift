import XCTest
import AppKit
@testable import Console

// MARK: - NoteVoiceCommand Tests

final class NoteVoiceCommandTests: XCTestCase {

    func testMatchCopy() {
        XCTAssertEqual(NoteVoiceCommand.match("copy"), .copy)
        XCTAssertEqual(NoteVoiceCommand.match("Copy"), .copy)
        XCTAssertEqual(NoteVoiceCommand.match("  copy  "), .copy)
    }

    func testMatchUndo() {
        XCTAssertEqual(NoteVoiceCommand.match("undo"), .undo)
        XCTAssertEqual(NoteVoiceCommand.match("Undo"), .undo)
    }

    func testMatchDone() {
        XCTAssertEqual(NoteVoiceCommand.match("done"), .done)
        XCTAssertEqual(NoteVoiceCommand.match("Done"), .done)
    }

    func testMatchIgnoresNonLetterCharacters() {
        XCTAssertEqual(NoteVoiceCommand.match("copy!"), .copy)
        XCTAssertEqual(NoteVoiceCommand.match("done."), .done)
        XCTAssertEqual(NoteVoiceCommand.match("undo?"), .undo)
    }

    func testMatchReturnsNilForUnknown() {
        XCTAssertNil(NoteVoiceCommand.match("hello"))
        XCTAssertNil(NoteVoiceCommand.match(""))
        XCTAssertNil(NoteVoiceCommand.match("copying"))
        XCTAssertNil(NoteVoiceCommand.match("undone"))
    }

    func testMatchReturnsNilForMultiWord() {
        XCTAssertNil(NoteVoiceCommand.match("copy that"))
        XCTAssertNil(NoteVoiceCommand.match("undo please"))
    }
}

// MARK: - NoteDictationMode Lifecycle Tests

@available(macOS 26.0, *)
final class NoteDictationModeTests: XCTestCase {

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

    @MainActor
    func testActivateSetsIsActive() async {
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let mode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        XCTAssertFalse(mode.isActive)

        await mode.activate(audioStream: nil)

        XCTAssertTrue(mode.isActive)
        await mode.deactivate()
    }

    @MainActor
    func testDeactivateClearsState() async {
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let mode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        await mode.activate(audioStream: nil)
        XCTAssertTrue(mode.isActive)

        await mode.deactivate()

        XCTAssertFalse(mode.isActive)
        XCTAssertTrue(mode.volatileText.isEmpty)
    }

    @MainActor
    func testActivateViaAudioSessionController() async {
        let controller = AudioSessionController.shared
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        let mode = NoteDictationMode(noteViewModel: vm, aiProviderManager: AIProviderManager())

        let success = await controller.requestMode(mode)

        XCTAssertTrue(success)
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(controller.activeMode === mode)

        await controller.releaseMode(mode)

        XCTAssertFalse(mode.isActive)
        XCTAssertNil(controller.activeMode)
    }
}

// MARK: - NoteViewModel.done Clipboard Tests (H18-F03)

@available(macOS 26.0, *)
final class NoteViewModelDoneTests: XCTestCase {

    @MainActor
    func testDoneCopiesVolatileTextWithNote() async {
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        vm.noteText = "alpha "
        vm.appendVolatileText("beta")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(vm.volatileText, "beta")

        let previousClipboard = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        defer {
            NSPasteboard.general.clearContents()
            if let previousClipboard {
                NSPasteboard.general.setString(previousClipboard, forType: .string)
            }
        }

        vm.done()
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha beta")
    }

    @MainActor
    func testDoneCopiesOnlyCommittedTextWhenVolatileFinalized() async {
        let vm = NoteViewModel(aiProviderManager: AIProviderManager())
        vm.noteText = "committed text"

        let previousClipboard = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        defer {
            NSPasteboard.general.clearContents()
            if let previousClipboard {
                NSPasteboard.general.setString(previousClipboard, forType: .string)
            }
        }

        vm.done()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "committed text")
    }
}
