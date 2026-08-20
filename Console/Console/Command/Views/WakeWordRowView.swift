import SwiftUI

struct WakeWordRowView: View {
    let wakeWord: WakeWord
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: wakeWord.isEnabled ? "waveform.circle.fill" : "waveform.circle")
                .font(.title3)
                .foregroundStyle(wakeWord.isEnabled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(wakeWord.word)
                    .font(.body)
                    .foregroundStyle(wakeWord.isEnabled ? .primary : .secondary)

                Text(wakeWord.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)

            Toggle("", isOn: Binding(
                get: { wakeWord.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
