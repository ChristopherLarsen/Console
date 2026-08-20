import SwiftUI

struct CommandRowView: View {
    let command: Command
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: command.isEnabled ? "command.circle.fill" : "command.circle")
                    .font(.title3)
                    .foregroundStyle(command.isEnabled ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(command.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(command.isEnabled ? .primary : .secondary)

                    if let firstPhrase = command.triggerPhrases.first {
                        HStack(spacing: 3) {
                            Text("Say:")
                                .font(.caption)
                                .foregroundStyle(.gray)
                            Text("\"\(firstPhrase)\"")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Label("\(command.actions.count)", systemImage: "arrow.right.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(command.executionMode.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { command.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
