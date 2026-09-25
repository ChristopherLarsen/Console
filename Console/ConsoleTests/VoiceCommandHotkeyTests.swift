import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Console

@MainActor
final class VoiceCommandHotkeyTests: XCTestCase {

    // MARK: - Sidebar voice navigation

    func testSidebarNamesNavigate() {
        let cases: [(String, SidebarSelection)] = [
            ("JIRA", .jira), ("Gira.", .jira), ("GitLab", .mergeRequests), ("git lab", .mergeRequests),
            ("open sessions", .sessions), ("Go to the brief", .brief), ("home", .home),
            ("show me settings please", .settings), ("Commands", .commands),
        ]
        for (utterance, expected) in cases {
            XCTAssertEqual(SidebarVoiceNavigation.destination(for: utterance, aiProviderEnabled: false), expected, utterance)
        }
    }

    func testLongerCommandsAndHiddenDestinationsDoNotNavigate() {
        XCTAssertNil(SidebarVoiceNavigation.destination(for: "open jira and create a ticket", aiProviderEnabled: true))
        XCTAssertNil(SidebarVoiceNavigation.destination(for: "take a note", aiProviderEnabled: true))
        XCTAssertNil(SidebarVoiceNavigation.destination(for: "AI provider", aiProviderEnabled: false))
        XCTAssertEqual(SidebarVoiceNavigation.destination(for: "AI provider", aiProviderEnabled: true), .aiProvider)
    }

    // MARK: - Key recognition

    func testTildeKeyWithOrWithoutShiftTriggers() {
        let grave = UInt16(kVK_ANSI_Grave)
        XCTAssertTrue(VoiceCommandHotkeyMonitor.isTildeTap(keyCode: grave, modifiers: [], isRepeat: false))
        XCTAssertTrue(VoiceCommandHotkeyMonitor.isTildeTap(keyCode: grave, modifiers: .shift, isRepeat: false))
        XCTAssertFalse(VoiceCommandHotkeyMonitor.isTildeTap(keyCode: grave, modifiers: .command, isRepeat: false),
                       "⌘` switches windows and must keep working")
        XCTAssertFalse(VoiceCommandHotkeyMonitor.isTildeTap(keyCode: grave, modifiers: [], isRepeat: true))
        XCTAssertFalse(VoiceCommandHotkeyMonitor.isTildeTap(keyCode: UInt16(kVK_ANSI_1), modifiers: [], isRepeat: false))
    }

    func testDefaultKeyIsTilde() {
        let defaults = UserDefaults(suiteName: "VoiceCommandHotkeyTests-\(UUID().uuidString)")!
        XCTAssertEqual(VoiceCommandHotkey.current(defaults), .tilde)
        defaults.set(VoiceCommandHotkey.function.rawValue, forKey: VoiceCommandHotkey.settingsKey)
        XCTAssertEqual(VoiceCommandHotkey.current(defaults), .function)
    }

    func testFunctionKeyTapRequiresAQuickLonePress() {
        var tap = FunctionKeyTap()
        XCTAssertFalse(tap.flagsChanged(fnDown: true, otherModifiers: false, at: 1.0))
        XCTAssertTrue(tap.flagsChanged(fnDown: false, otherModifiers: false, at: 1.2))

        XCTAssertFalse(tap.flagsChanged(fnDown: true, otherModifiers: false, at: 2.0))
        XCTAssertFalse(tap.flagsChanged(fnDown: false, otherModifiers: false, at: 2.9), "a long hold is not a tap")

        XCTAssertFalse(tap.flagsChanged(fnDown: true, otherModifiers: false, at: 3.0))
        tap.otherKeyPressed()
        XCTAssertFalse(tap.flagsChanged(fnDown: false, otherModifiers: false, at: 3.1), "fn+arrow is not a tap")

        XCTAssertFalse(tap.flagsChanged(fnDown: true, otherModifiers: true, at: 4.0))
        XCTAssertFalse(tap.flagsChanged(fnDown: false, otherModifiers: false, at: 4.1), "fn with another modifier is not a tap")
    }

    func testTextInputFocusKeepsTheKey() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let plain = NSView(frame: NSRect(x: 0, y: 40, width: 50, height: 20))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(plain)
        window.makeFirstResponder(field)
        XCTAssertTrue(VoiceCommandHotkeyMonitor.isTextInputFocused(window))
        window.makeFirstResponder(nil)
        XCTAssertFalse(VoiceCommandHotkeyMonitor.isTextInputFocused(window))
    }

    // MARK: - Push-to-talk capture

    func testPushToTalkCapturesTheWholeUtteranceWithoutAWakeWord() async {
        let mode = CommandListeningMode(transcriptSource: SyntheticTranscriptSource([]))
        mode.updateWakeWords(["console"], allWakeWords: ["console"])
        XCTAssertFalse(mode.beginPushToTalkCapture(), "an inactive mode cannot capture")
        await mode.activate(audioStream: nil)

        var command: String?
        mode.onCommandTranscribed = { command = $0 }
        XCTAssertTrue(mode.beginPushToTalkCapture())
        XCTAssertEqual(mode.listeningState, .commandListening)
        XCTAssertFalse(mode.beginPushToTalkCapture(), "already capturing")

        mode.handleTranscriptUpdate("GitLab", isFinal: true)
        XCTAssertEqual(command, "GitLab")
        XCTAssertEqual(mode.listeningState, .passive)
        await mode.deactivate()
    }
}
