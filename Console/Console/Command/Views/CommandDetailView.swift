import SwiftUI
import SwiftData

struct CommandDetailView: View {
    @Bindable var command: Command
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var newPhrase = ""
    @State private var errorMessage: String?
    @State private var showLastPhraseAlert = false
    @State private var cachedDescriptionKey: LocalizedStringKey?
    @State private var cachedDescriptionSource = ""
    @State private var savedName = ""
    @State private var savedTriggerPhrases: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    commandPhrasesCard
                    actionsCard

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 450, maxHeight: 750)
        .onAppear {
            savedName = command.name
            savedTriggerPhrases = command.triggerPhrases
        }
        .alert("Command Phrase Required", isPresented: $showLastPhraseAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All commands must have at least one command phrase. You cannot remove the last one.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("Command Name", text: $command.name)
                .textFieldStyle(.plain)
                .font(.title3.bold())
                .accessibilityIdentifier("Command Name")
                .onChange(of: command.name) { _, newValue in
                    let sanitized = InputSanitizer.commandName(newValue)
                    if sanitized != newValue { command.name = sanitized }
                }

            Spacer()

            CloseButton { cancel() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Command Phrases

    private var commandPhrasesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COMMAND PHRASES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if !command.triggerPhrases.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(command.triggerPhrases.enumerated()), id: \.offset) { index, phrase in
                        HStack(spacing: 4) {
                            Text(phrase)
                                .font(.callout)

                            Button {
                                removePhrase(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add a command phrase", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: newPhrase) { _, newValue in
                        let sanitized = InputSanitizer.commandPhrase(newValue)
                        if sanitized != newValue { newPhrase = sanitized }
                    }
                    .onSubmit { addPhrase() }

                CapsuleButton("Add", isDisabled: newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    addPhrase()
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if DEBUG
            if DeveloperModeManager.shared.isDeveloperModeEnabled {
                debugActionsContent
            } else {
                releaseActionsContent
            }
            #else
            releaseActionsContent
            #endif
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var releaseActionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIONS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(descriptionKey)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var debugActionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ACTIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(command.actions.count) step\(command.actions.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let sortedActions = command.actions.sorted(by: { $0.order < $1.order })
            ForEach(Array(sortedActions.enumerated()), id: \.element.id) { index, action in
                readOnlyActionRow(index: index, action: action)
            }

            HStack(spacing: 8) {
                Label(command.executionMode.rawValue, systemImage: "gearshape")
                if command.requiresConfirmation {
                    Label("Confirmation required", systemImage: "shield")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
    }

    private func readOnlyActionRow(index: Int, action: CommandAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(action.type.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())

                ScrollView {
                    Group {
                        if action.type == .appleScript {
                            Text(AppleScriptHighlighter.highlight(action.payload))
                        } else {
                            Text(action.payload)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 24, maxHeight: 80)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var descriptionKey: LocalizedStringKey {
        let source = command.displayActionDescription
        if cachedDescriptionSource == source, let key = cachedDescriptionKey {
            return key
        }
        let key = LocalizedStringKey(source)
        DispatchQueue.main.async {
            cachedDescriptionSource = source
            cachedDescriptionKey = key
        }
        return key
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            CapsuleButton("Cancel", style: .neutral) {
                cancel()
            }
            .accessibilityIdentifier("Cancel")
            .keyboardShortcut(.cancelAction)

            Spacer()

            CapsuleButton("Save") {
                save()
                dismiss()
            }
            .accessibilityIdentifier("Save")
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func cancel() {
        command.name = savedName
        command.triggerPhrases = savedTriggerPhrases
        dismiss()
    }

    private func addPhrase() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        guard !command.triggerPhrases.contains(where: { $0.lowercased() == phrase.lowercased() }) else { return }

        // Same guards as command creation: a phrase owned by another command
        // makes both unvoiceable, and reserved phrases belong to system commands.
        let normalized = phrase.lowercased()
        let descriptor = FetchDescriptor<Command>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        let isOwnedByOther = existing.contains { other in
            other.id != command.id
                && other.triggerPhrases.contains { $0.lowercased() == normalized }
        }
        if isOwnedByOther {
            errorMessage = "'\(phrase)' is already used by another command."
            return
        }

        let reservedPhrases = ConsoleCommandRegistry.all
            .flatMap { $0.triggerPhrases }
            .map { $0.lowercased() }
        if reservedPhrases.contains(normalized) {
            errorMessage = "'\(phrase)' is reserved for a system command and cannot be used."
            return
        }

        command.triggerPhrases.append(phrase)
        newPhrase = ""
        errorMessage = nil
    }

    private func removePhrase(at index: Int) {
        guard command.triggerPhrases.indices.contains(index) else { return }
        guard command.triggerPhrases.count > 1 else {
            showLastPhraseAlert = true
            return
        }
        command.triggerPhrases.remove(at: index)
    }

    private func save() {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        } catch {
            printDebug("[Console] Failed to save command edits: \(error)")
        }
    }
}
