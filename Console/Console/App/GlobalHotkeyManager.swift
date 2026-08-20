import AppKit
import Observation
import Carbon.HIToolbox

/// Manages a user-configurable global hotkey that brings the app window to front.
@Observable
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private static let keyCodeKey = "globalHotkeyKeyCode"
    private static let modifiersKey = "globalHotkeyModifiers"

    // Default: ⌃⌥⌘T
    private static let defaultKeyCode: UInt16 = 17
    private static let defaultModifiers: UInt = NSEvent.ModifierFlags([.control, .option, .command]).rawValue

    var keyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeKey); UserDefaults.standard.synchronize() }
    }
    var modifierFlags: NSEvent.ModifierFlags {
        didSet { UserDefaults.standard.set(modifierFlags.rawValue, forKey: Self.modifiersKey); UserDefaults.standard.synchronize() }
    }

    private var monitor: Any?
    private var localMonitor: Any?

    /// Human-readable representation of the current hotkey
    var displayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(stringForKeyCode(keyCode))
        return parts.joined()
    }

    private init() {
        let storedCode = UserDefaults.standard.object(forKey: Self.keyCodeKey) as? Int
        let storedMods = UserDefaults.standard.object(forKey: Self.modifiersKey) as? UInt

        self.keyCode = UInt16(storedCode ?? Int(Self.defaultKeyCode))
        self.modifierFlags = NSEvent.ModifierFlags(rawValue: storedMods ?? Self.defaultModifiers)
    }

    func install() {
        uninstall()
        let targetCode = keyCode
        let relevantMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let targetMods = modifierFlags.intersection(relevantMods)

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGlobalKeyEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventMods = event.modifierFlags.intersection(relevantMods)
            guard event.keyCode == targetCode, eventMods == targetMods else { return event }
            Task { @MainActor [weak self] in
                self?.handleGlobalKeyEvent(event)
            }
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    /// Updates the hotkey and reinstalls the monitor
    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers
        install()
    }

    private func handleGlobalKeyEvent(_ event: NSEvent) {
        let relevantMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let eventMods = event.modifierFlags.intersection(relevantMods)
        let targetMods = modifierFlags.intersection(relevantMods)
        guard event.keyCode == keyCode, eventMods == targetMods else { return }
        bringAppToFront()
        NotificationCenter.default.post(name: .globalHotkeyPressed, object: nil)
    }

    private func bringAppToFront() {
        ConsoleWindowManager.bringToFront("main")
    }

    /// Converts a macOS virtual key code to a display string
    func stringForKeyCode(_ code: UInt16) -> String {
        let specialKeys: [UInt16: String] = [
            UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
            UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        ]
        if let special = specialKeys[code] { return special }

        // Use TISCopyCurrentKeyboardInputSource for character lookup
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layoutData = unsafeBitCast(layoutPtr, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { rawBuf -> String in
            guard let baseAddr = rawBuf.baseAddress else { return "?" }
            let layoutRef = baseAddr.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length: Int = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layoutRef, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars
            )
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
