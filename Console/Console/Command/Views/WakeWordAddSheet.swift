import SwiftUI

struct WakeWordAddSheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var wordText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Trigger Word")
                .font(.headline)

            TextField("Enter a trigger word", text: $wordText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Enter a trigger word")
                .focused($isFocused)
                .onChange(of: wordText) { _, newValue in
                    let sanitized = InputSanitizer.triggerWord(newValue)
                    if sanitized != newValue { wordText = sanitized }
                }
                .onSubmit { addAndDismiss() }

            Text("Say this word and Console will listen for your next command.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.buttonNeutralBackgroundColor)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Button {
                    addAndDismiss()
                } label: {
                    Text("Add")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("Add")
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(wordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }

    private func addAndDismiss() {
        let trimmed = wordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        dismiss()
    }
}
