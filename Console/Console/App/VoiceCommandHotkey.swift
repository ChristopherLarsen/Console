import AppKit
import Carbon.HIToolbox
import WebKit
import SwiftTerm

/// Which key starts a push-to-talk voice command.
enum VoiceCommandHotkey: String, CaseIterable, Identifiable {
    /// The `~` / `` ` `` key (left of 1 on US keyboards), with or without Shift.
    case tilde
    /// A tap of the fn (globe) key on its own.
    case function
    case off

    static let settingsKey = "voiceCommandHotkey"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tilde: return "~ key"
        case .function: return "fn key"
        case .off: return "Off"
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> VoiceCommandHotkey {
        defaults.string(forKey: settingsKey).flatMap(Self.init(rawValue:)) ?? .tilde
    }
}

/// Watches Console's own key events for the voice-command hotkey. Local
/// monitors only: it works while Console is frontmost and needs no Input
/// Monitoring permission. The `~` key never fires while a text field, terminal
/// or web page has keyboard focus, so it keeps typing there; a lone fn tap
/// types nothing and works everywhere in Console.
@MainActor
final class VoiceCommandHotkeyMonitor {
    static let shared = VoiceCommandHotkeyMonitor()

    /// Runs on a recognized tap.
    var onTrigger: (@MainActor () -> Void)?

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var fnTap = FunctionKeyTap()

    func install() {
        uninstall()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) ?? event }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
            return event
        }
    }

    func uninstall() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        fnTap.otherKeyPressed()
        guard VoiceCommandHotkey.current() == .tilde,
              Self.isTildeTap(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat),
              !Self.isTextInputFocused(event.window) else { return event }
        onTrigger?()
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard VoiceCommandHotkey.current() == .function else { return }
        let fnDown = event.modifierFlags.contains(.function)
        let others = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        // A lone fn tap types nothing, so it works even while typing.
        if fnTap.flagsChanged(fnDown: fnDown, otherModifiers: others, at: event.timestamp) {
            onTrigger?()
        }
    }

    /// The grave/tilde key with no Command, Control or Option. Shift is allowed
    /// because it is how `~` is typed.
    nonisolated static func isTildeTap(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        keyCode == UInt16(kVK_ANSI_Grave) && !isRepeat
            && modifiers.intersection([.command, .control, .option, .function]).isEmpty
    }

    /// Text fields, text views (including field editors), terminals and web
    /// pages keep their keys.
    static func isTextInputFocused(_ window: NSWindow?) -> Bool {
        guard let responder = (window ?? NSApp.keyWindow)?.firstResponder as? NSView else { return false }
        var view: NSView? = responder
        while let current = view {
            if current is NSText || current is NSTextField || current is TerminalView || current is WKWebView {
                return true
            }
            view = current.superview
        }
        return false
    }
}

/// A tap is fn pressed and released on its own within `maxDuration`, with no
/// other key or modifier in between (fn+arrow and similar never count).
struct FunctionKeyTap {
    static let maxDuration: TimeInterval = 0.4

    private var pressedAt: TimeInterval?
    private var interrupted = false

    mutating func otherKeyPressed() {
        interrupted = true
    }

    /// Returns true when this change completes a tap.
    mutating func flagsChanged(fnDown: Bool, otherModifiers: Bool, at time: TimeInterval) -> Bool {
        if fnDown {
            pressedAt = time
            interrupted = otherModifiers
            return false
        }
        defer { pressedAt = nil; interrupted = false }
        guard let pressedAt, !interrupted, !otherModifiers else { return false }
        return time - pressedAt <= Self.maxDuration
    }
}
