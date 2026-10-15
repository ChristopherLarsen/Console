import SwiftUI
import SwiftData

struct TriggersView: View {
    @Environment(WakeWordManager.self) private var wakeWordManager: WakeWordManager?

    @State private var showAddWakeWord = false
    @State private var showLastWordAlert = false
    @State private var lastWordAlertMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    triggerWordsSection
                }
                .formStyle(.grouped)
            }
        }
        .sheet(isPresented: $showAddWakeWord) {
            WakeWordAddSheet(onAdd: { word in
                wakeWordManager?.addWakeWord(word)
                syncDetectorWakeWords()
            })
        }
        .alert("Trigger Word Required", isPresented: $showLastWordAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastWordAlertMessage)
        }
    }

    private func syncDetectorWakeWords() {
        guard let wakeWordManager else { return }
        if #available(macOS 26.0, *) {
            CommandListeningMode.pushWakeWords(
                wakeWordManager.enabledWords,
                to: AudioSessionController.shared
            )
        }
    }

    private func deleteWakeWord(_ word: WakeWord) {
        guard let wakeWordManager else { return }
        let deleted = wakeWordManager.deleteWakeWord(word)
        if deleted {
            syncDetectorWakeWords()
        } else {
            lastWordAlertMessage = "This is your last enabled trigger word and cannot be deleted. At least one trigger word must remain active."
            showLastWordAlert = true
        }
    }

    private func toggleWakeWord(_ word: WakeWord) {
        guard let wakeWordManager else { return }
        let toggled = wakeWordManager.toggleWakeWord(word)
        if toggled {
            syncDetectorWakeWords()
        } else {
            lastWordAlertMessage = "This is your last enabled trigger word and cannot be disabled. At least one trigger word must remain active."
            showLastWordAlert = true
        }
    }

    // MARK: - Trigger Words

    private var triggerWordsSection: some View {
        Section {
            if let wakeWordManager {
                ForEach(wakeWordManager.wakeWords) { word in
                    TriggerWordRow(
                        word: word,
                        onToggle: { toggleWakeWord(word) },
                        onDelete: { deleteWakeWord(word) }
                    )
                }

            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Trigger Words")
                if let wakeWordManager {
                    Text("\(wakeWordManager.enabledWords.count) enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.none)
                }
                Spacer()
                Button {
                    showAddWakeWord = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 25))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("addTriggerWordButton")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\u{2022}  Say any enabled trigger word to activate command listening.")
                Text("\u{2022}  Multiple trigger words work as OR logic \u{2014} any one of them will trigger listening.")
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Trigger Word Row

private struct TriggerWordRow: View {
    let word: WakeWord
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.primary)
                .frame(width: 20)

            Text(word.word)

            if !word.isEnabled {
                Text("(disabled)")
                    .font(.subheadline)
                    .foregroundStyle(.gray.opacity(0.6))
            }

            Spacer()

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)

            Toggle("", isOn: Binding(
                get: { word.isEnabled },
                set: { _ in onToggle() }
            ))
            .themedToggleStyle()
            .labelsHidden()
            .fixedSize()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
