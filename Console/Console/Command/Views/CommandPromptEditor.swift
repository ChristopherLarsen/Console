import SwiftUI
import SwiftData

/// Manual title and prompt form. Saving does not call a language model.
struct CommandPromptEditor: View {
    private let existing: Command?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var prompt: String
    @State private var errorMessage: String?

    init(command: Command? = nil) {
        existing = command
        _title = State(initialValue: command?.name ?? "")
        _prompt = State(initialValue: command?.claudePrompt ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "Create Command" : "Edit Command")
                    .font(.headline)
                Spacer()
                CloseButton { dismiss() }
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title")
                        .font(.subheadline.weight(.medium))
                    TextField("Command title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("Command Title")
                        .onChange(of: title) { _, newValue in
                            let sanitized = InputSanitizer.commandName(newValue)
                            if sanitized != newValue { title = sanitized }
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.subheadline.weight(.medium))
                    Text("This text is sent as the first message in a new Claude session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 160, maxHeight: 280)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .accessibilityIdentifier("Command Prompt")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)

            Divider()

            HStack {
                CapsuleButton("Cancel", style: .neutral) { dismiss() }
                Spacer()
                CapsuleButton("Save", style: .primary, isDisabled: !canSave) {
                    save()
                }
                .accessibilityIdentifier("Save Command")
            }
            .padding(16)
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 420, maxHeight: 560)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let name = InputSanitizer.commandName(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = InputSanitizer.commandPrompt(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Enter a title."
            return
        }
        guard !body.isEmpty else {
            errorMessage = "Enter the text Claude should run."
            return
        }

        if let existing {
            existing.name = name
            existing.claudePrompt = body
            existing.shortSummary = CommandPromptText.hint(from: body, lineCount: 1)
        } else {
            let command = Command(
                name: name,
                claudePrompt: body,
                shortSummary: CommandPromptText.hint(from: body, lineCount: 1)
            )
            modelContext.insert(command)
        }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
            dismiss()
        } catch {
            errorMessage = "Could not save this command."
        }
    }
}
