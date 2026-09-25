import SwiftUI

/// Settings section for the push-to-talk voice-command key. Shown in
/// Settings and in Commands → Triggers.
struct VoiceCommandHotkeySection: View {
    @AppStorage(VoiceCommandHotkey.settingsKey) private var voiceCommandHotkey: VoiceCommandHotkey = .tilde

    var body: some View {
        Section {
            Picker("Voice command key", selection: $voiceCommandHotkey) {
                ForEach(VoiceCommandHotkey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .accessibilityIdentifier("VoiceCommandHotkeyPicker")
        } header: {
            Text("Voice Command Key")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\u{2022}  Tap the key, then say a destination such as \u{201C}JIRA\u{201D}, \u{201C}GitLab\u{201D} or \u{201C}Sessions\u{201D} to open it. Any other command works as if you had said a trigger word.")
                Text("\u{2022}  Works while Console is in front, with no trigger word needed.")
                switch voiceCommandHotkey {
                case .tilde:
                    Text("\u{2022}  The ~ key is ignored while you type in a text field, terminal or web page, so it still types there. Choose fn to use voice commands from those too.")
                case .function:
                    Text("\u{2022}  A tap of fn on its own works everywhere in Console. If macOS also reacts to fn, set System Settings \u{2192} Keyboard \u{2192} \u{201C}Press \u{1F310} key to\u{201D} to Do Nothing.")
                case .off:
                    EmptyView()
                }
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
