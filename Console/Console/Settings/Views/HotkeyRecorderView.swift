import SwiftUI
import Carbon.HIToolbox

/// Modal view that captures a new global hotkey from the user.
struct HotkeyRecorderView: View {
    var onSave: (UInt16, NSEvent.ModifierFlags) -> Void
    var onDismiss: () -> Void

    @State private var isRecording = false
    @State private var capturedKeyCode: UInt16?
    @State private var capturedModifiers: NSEvent.ModifierFlags?
    @State private var errorMessage: String?
    @State private var conflictWarning: String?
    @State private var localMonitor: Any?

    private var currentDisplay: String {
        if isRecording { return "Press a key combination..." }
        if let code = capturedKeyCode, let mods = capturedModifiers {
            return formatHotkey(keyCode: code, modifiers: mods)
        }
        return GlobalHotkeyManager.shared.displayString
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CloseButton(action: { cleanup(); onDismiss() })
            }
            .padding(.trailing, 16)
            .padding(.top, 12)

            Text("Global Hotkey")
                .font(.title2.bold())
                .padding(.bottom, 6)

            Text("You will use this key combination to show Console.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            // Hotkey display
            Text(currentDisplay)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(minWidth: 200)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 2 : 1)
                        )
                )
                .padding(.bottom, 8)

            if let warning = conflictWarning {
                conflictBanner(warning)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            if !isRecording {
                Button("Record New Hotkey") { startRecording() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .controlSize(.regular)
                    .padding(.bottom, 16)
            } else {
                Button("Cancel Recording") { stopRecording() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .controlSize(.regular)
                    .padding(.bottom, 16)
            }

            HStack(spacing: 12) {
                CapsuleButton("Reset to Default", style: .neutral) {
                    capturedKeyCode = 17
                    capturedModifiers = [.control, .option, .command]
                    conflictWarning = nil
                    errorMessage = nil
                }

                Spacer()

                CapsuleButton("Save") {
                    let code = capturedKeyCode ?? GlobalHotkeyManager.shared.keyCode
                    let mods = capturedModifiers ?? GlobalHotkeyManager.shared.modifierFlags
                    if let conflict = checkForConsoleConflict(keyCode: code, modifiers: mods) {
                        // Saving a Console-internal chord silently swallows that
                        // navigation everywhere; refuse instead.
                        errorMessage = "\(conflict). Pick a different combination."
                        return
                    }
                    cleanup()
                    onSave(code, mods)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 380)
        .onDisappear { cleanup() }
    }

    // MARK: - Conflict Banner

    private func conflictBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.accentColor)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Recording

    private func startRecording() {
        errorMessage = nil
        conflictWarning = nil
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordedKey(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleRecordedKey(_ event: NSEvent) {
        let relevantMods = event.modifierFlags.intersection([.control, .option, .shift, .command])

        // Escape cancels recording
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        // Must include at least one modifier
        guard !relevantMods.isEmpty else {
            errorMessage = "Hotkey must include at least one modifier (⌃ ⌥ ⇧ ⌘)"
            return
        }

        // Reject modifier-only presses
        let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierOnlyKeyCodes.contains(event.keyCode) else { return }

        let warning = checkForSystemConflict(keyCode: event.keyCode, modifiers: relevantMods)
        let consoleConflict = checkForConsoleConflict(keyCode: event.keyCode, modifiers: relevantMods)

        capturedKeyCode = event.keyCode
        capturedModifiers = relevantMods
        conflictWarning = consoleConflict ?? warning
        errorMessage = nil
        stopRecording()
    }

    private func cleanup() {
        stopRecording()
    }

    // MARK: - Conflict Detection

    private struct SystemShortcut {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let name: String
    }

    private static let knownSystemShortcuts: [SystemShortcut] = [
        // App lifecycle
        .init(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command], name: "⌘H — Hide App"),
        .init(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command, .option], name: "⌥⌘H — Hide Others"),
        .init(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command], name: "⌘Q — Quit App"),
        .init(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command], name: "⌘W — Close Window"),
        .init(keyCode: UInt16(kVK_ANSI_M), modifiers: [.command], name: "⌘M — Minimize"),
        // Editing
        .init(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command], name: "⌘Z — Undo"),
        .init(keyCode: UInt16(kVK_ANSI_X), modifiers: [.command], name: "⌘X — Cut"),
        .init(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command], name: "⌘C — Copy"),
        .init(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command], name: "⌘V — Paste"),
        .init(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command], name: "⌘A — Select All"),
        // File operations
        .init(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command], name: "⌘N — New"),
        .init(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command], name: "⌘O — Open"),
        .init(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command], name: "⌘S — Save"),
        .init(keyCode: UInt16(kVK_ANSI_P), modifiers: [.command], name: "⌘P — Print"),
        .init(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command], name: "⌘F — Find"),
        .init(keyCode: UInt16(kVK_ANSI_Comma), modifiers: [.command], name: "⌘, — Settings"),
        // System
        .init(keyCode: UInt16(kVK_Tab), modifiers: [.command], name: "⌘Tab — App Switcher"),
        .init(keyCode: UInt16(kVK_Space), modifiers: [.command], name: "⌘Space — Spotlight"),
        .init(keyCode: UInt16(kVK_Space), modifiers: [.control, .command], name: "⌃⌘Space — Character Viewer"),
        // Mission Control
        .init(keyCode: UInt16(kVK_UpArrow), modifiers: [.control], name: "⌃↑ — Mission Control"),
        .init(keyCode: UInt16(kVK_DownArrow), modifiers: [.control], name: "⌃↓ — App Expose"),
        .init(keyCode: UInt16(kVK_LeftArrow), modifiers: [.control], name: "⌃← — Move Space Left"),
        .init(keyCode: UInt16(kVK_RightArrow), modifiers: [.control], name: "⌃→ — Move Space Right"),
        // Screenshots
        .init(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .shift], name: "⇧⌘3 — Screenshot"),
        .init(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift], name: "⇧⌘4 — Screenshot Selection"),
        .init(keyCode: UInt16(kVK_ANSI_5), modifiers: [.command, .shift], name: "⇧⌘5 — Screenshot Toolbar"),
    ]

    private func checkForSystemConflict(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let inputMods = modifiers.intersection([.control, .option, .shift, .command])

        // Exact match — direct conflict
        for shortcut in Self.knownSystemShortcuts {
            if shortcut.keyCode == keyCode && shortcut.modifiers == inputMods {
                return "Conflicts with \(shortcut.name)"
            }
        }

        // Superset match — same key with additional modifiers overlaps a system shortcut
        let bestMatch = Self.knownSystemShortcuts
            .filter { $0.keyCode == keyCode && inputMods.contains($0.modifiers) && inputMods != $0.modifiers }
            .max(by: { $0.modifiers.rawValue.nonzeroBitCount < $1.modifiers.rawValue.nonzeroBitCount })

        if let match = bestMatch {
            return "Overlaps with \(match.name)"
        }

        return nil
    }

    // MARK: - Console Conflict Detection

    /// Chords Console itself consumes (Go menu navigation and session
    /// shortcuts). A global hotkey matching one of these is swallowed by the
    /// local key monitor before the menu ever sees it.
    private static let consoleShortcuts: [SystemShortcut] = {
        let digits: [UInt16] = [
            UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4),
            UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8),
            UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_0),
        ]
        var shortcuts: [SystemShortcut] = []
        for (offset, code) in digits.enumerated() {
            let number = offset < 9 ? offset + 1 : 0
            shortcuts.append(.init(keyCode: code, modifiers: [.control], name: "⌃\(number) — Console sidebar navigation"))
            shortcuts.append(.init(keyCode: code, modifiers: [.command], name: "⌘\(number) — Console session shortcut"))
        }
        shortcuts.append(.init(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command], name: "⌘` — Console sidebar Sessions"))
        return shortcuts
    }()

    private func checkForConsoleConflict(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let inputMods = modifiers.intersection([.control, .option, .shift, .command])
        for shortcut in Self.consoleShortcuts where shortcut.keyCode == keyCode && shortcut.modifiers == inputMods {
            return "Conflicts with \(shortcut.name)"
        }
        return nil
    }

    // MARK: - Display

    private func formatHotkey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(GlobalHotkeyManager.shared.stringForKeyCode(keyCode))
        return parts.joined()
    }
}
