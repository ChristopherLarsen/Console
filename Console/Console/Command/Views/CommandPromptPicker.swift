import SwiftUI
import SwiftData

/// Title list opened from the sidebar buddy. Choosing a row runs it immediately.
struct CommandPromptPicker: View {
    var onRan: () -> Void

    @Query(sort: \Command.name) private var commands: [Command]
    @Environment(LocalCommandExecutor.self) private var commandExecutor

    private var promptCommands: [Command] {
        commands
            .filter { $0.isEnabled && $0.isClaudePromptCommand }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Commands")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if promptCommands.isEmpty {
                Text("No commands yet. Add one from Commands.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(promptCommands) { command in
                            Button {
                                let selected = command
                                onRan()
                                Task { _ = await commandExecutor.execute(selected) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.name)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(CommandPromptText.hint(from: command.claudePrompt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(command.name)
                            .accessibilityHint(CommandPromptText.hint(from: command.claudePrompt))
                        }
                    }
                }
                .frame(maxHeight: 360)
                .padding(.bottom, 6)
            }
        }
        .frame(width: 320)
    }
}
