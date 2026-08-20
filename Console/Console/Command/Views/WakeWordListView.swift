import SwiftUI

struct WakeWordListView: View {
    var wakeWordManager: WakeWordManager

    @State private var showAddSheet = false
    @State private var showLastWordAlert = false
    @State private var lastWordAlertMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if wakeWordManager.wakeWords.isEmpty {
                emptyState
            } else {
                wordList
            }
        }
        .navigationTitle("Trigger Words")
        .sheet(isPresented: $showAddSheet) {
            WakeWordAddSheet(onAdd: { word in
                wakeWordManager.addWakeWord(word)
                syncDetectorWakeWords()
            })
        }
        .alert("Trigger Word Required", isPresented: $showLastWordAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastWordAlertMessage)
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger Words")
                    .font(.headline)
                Text("Say any of these words to activate command listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityIdentifier("addTriggerWordButton")
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private var wordList: some View {
        List {
            ForEach(wakeWordManager.wakeWords) { wakeWord in
                WakeWordRowView(
                    wakeWord: wakeWord,
                    onToggle: { toggleWakeWord(wakeWord) },
                    onDelete: { deleteWakeWord(wakeWord) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No trigger words")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func syncDetectorWakeWords() {
        if #available(macOS 26.0, *),
           let mode = AudioSessionController.shared.activeMode as? CommandListeningMode {
            mode.updateWakeWords(wakeWordManager.enabledWords, allWakeWords: wakeWordManager.wakeWords.map(\.word))
        }
    }

    private func deleteWakeWord(_ word: WakeWord) {
        let deleted = wakeWordManager.deleteWakeWord(word)
        if deleted {
            syncDetectorWakeWords()
        } else {
            lastWordAlertMessage = "This is your last enabled trigger word and cannot be deleted. At least one trigger word must remain active."
            showLastWordAlert = true
        }
    }

    private func toggleWakeWord(_ word: WakeWord) {
        let toggled = wakeWordManager.toggleWakeWord(word)
        if toggled {
            syncDetectorWakeWords()
        } else {
            lastWordAlertMessage = "This is your last enabled trigger word and cannot be disabled. At least one trigger word must remain active."
            showLastWordAlert = true
        }
    }
}
